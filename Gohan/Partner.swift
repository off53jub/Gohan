import Foundation
import Observation
import SwiftData
import UIKit
import UniformTypeIdentifiers

// ふたり帖（便61〜64）。サーバーを使わず、ファイル（.gohan）を LINE や AirDrop で渡し合う。
// 受け取ると「ふたり」の画面に相手の食事が並び、同じ時間・同じ場所の食事は「ふたりで」と1つに見える。

extension UTType {
    static let gohanBook = UTType(exportedAs: "com.off53jub.gohan.book")
}

struct PartnerMeal: Codable, Identifiable, Hashable {
    var id: UUID
    var date: Date
    var latitude: Double?
    var longitude: Double?
    var title: String
    var placeKey: String?
    var placeName: String?
    var address: String?
    var genre: String
    var dishes: [String]
    var note: String
    var wantAgain: Bool
    /// 小さな写真（320px の JPEG。相手の端末には元の写真が無いので）
    var thumbnail: Data?
}

struct PartnerBook: Codable {
    var version = 1
    var name: String
    var sentAt = Date()
    var meals: [PartnerMeal]
    /// 送り主が、受け取り手の食事に付けた反応（受け取り手の食事の ID → 反応）
    var reactions: [String: [String]] = [:]
}

@MainActor
@Observable
final class PartnerStore {
    static let shared = PartnerStore()
    private(set) var book: PartnerBook?
    /// 自分が相手の食事に付けた反応（相手の食事の ID → 反応）。次に送るファイルに入れる
    private(set) var myReactions: [String: [String]] = [:]

    private var url: URL { URL.applicationSupportDirectory.appendingPathComponent("partner.json") }
    private var reactionsURL: URL { URL.applicationSupportDirectory.appendingPathComponent("partner-reactions.json") }

    static var myName: String {
        get { UserDefaults.standard.string(forKey: "partner.myName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "partner.myName") }
    }

    func load() {
        // 自分で保存したファイル
        if let data = try? Data(contentsOf: url) { book = try? JSONDecoder().decode(PartnerBook.self, from: data) }
        if let data = try? Data(contentsOf: reactionsURL) {
            myReactions = (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
        }
    }

    /// 受け取ったファイルを読む。相手が付けた反応は、自分の食事に写す
    func receive(_ fileURL: URL, context: ModelContext) throws -> Int {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        // 本人が開いた .gohan のファイル
        let data = try Data(contentsOf: fileURL)
        let incoming = try JSONDecoder().decode(PartnerBook.self, from: data)
        book = incoming
        try? data.write(to: url, options: .atomic)
        let meals = (try? context.fetch(FetchDescriptor<Meal>())) ?? []
        for meal in meals {
            if let r = incoming.reactions[meal.id.uuidString] { meal.reactions = r }
        }
        try? context.save()
        return incoming.meals.count
    }

    func react(_ mealID: UUID, _ text: String) {
        var list = myReactions[mealID.uuidString] ?? []
        if list.contains(text) { list.removeAll { $0 == text } } else { list.append(text) }
        myReactions[mealID.uuidString] = list
        if let data = try? JSONEncoder().encode(myReactions) { try? data.write(to: reactionsURL, options: .atomic) }
    }

    /// 自分の帖を、相手に渡すファイルにする（新しい 300 食まで）
    func makeFile(context: ModelContext) async -> URL? {
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden }, sortBy: [SortDescriptor(\.date, order: .reverse)])
        let meals = Array(((try? context.fetch(descriptor)) ?? []).prefix(300))
        var out: [PartnerMeal] = []
        for m in meals {
            var thumb: Data?
            if let id = m.photoIDs.first, let image = await ThumbCache.shared.image(id, side: 320) {
                thumb = image.jpegData(compressionQuality: 0.6)
            }
            out.append(PartnerMeal(id: m.id, date: m.date, latitude: m.latitude, longitude: m.longitude, title: m.title,
                                   placeKey: m.place?.key, placeName: m.place?.name, address: m.place?.address, genre: m.genre,
                                   dishes: m.dishes, note: m.note, wantAgain: m.place?.wantAgain ?? false, thumbnail: thumb))
        }
        let name = Self.myName.isEmpty ? "ふたり帖" : Self.myName
        let file = PartnerBook(name: name, meals: out, reactions: myReactions)
        guard let data = try? JSONEncoder().encode(file) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).gohan")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    /// 同じ時間（前後 90 分）・同じ場所（200m 以内）の、相手の食事（便62）
    func together(with meal: Meal) -> PartnerMeal? {
        guard let book else { return nil }
        return book.meals.first { p in
            guard abs(p.date.timeIntervalSince(meal.date)) <= 90 * 60 else { return false }
            if let a = p.placeKey, let b = meal.place?.key, a == b { return true }
            guard let lat = p.latitude, let lon = p.longitude, let mlat = meal.latitude, let mlon = meal.longitude else { return false }
            return Matcher.distance(lat, lon, mlat, mlon) <= 200
        }
    }

    func clear() {
        book = nil
        try? FileManager.default.removeItem(at: url)
    }
}
