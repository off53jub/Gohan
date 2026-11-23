import CryptoKit
import Foundation
import Photos
import SwiftData
import UIKit

/// 記録の写し（便7・便8）。機種変更や消えたときのために、ファイルに書き出す・読み戻す
struct BackupFile: Codable {
    var version = 1
    var exportedAt = Date()
    var meals: [MealRecord]
    var places: [PlaceRecord]
}

struct PlaceRecord: Codable {
    var key: String
    var name: String
    var address: String
    var category: String
    var latitude: Double
    var longitude: Double
    var wantAgain: Bool
    var note: String
    var firstVisit: Date
    var phone: String
    var nextWish: String
    var wantToTry: Bool
}

struct MealRecord: Codable {
    var id: UUID
    var date: Date
    var endDate: Date
    var photoIDs: [String]
    var cloudIDs: [String]
    var latitude: Double?
    var longitude: Double?
    var area: String
    var region: String
    var genre: String
    var dishes: [String]
    var summary: String
    var note: String
    var kind: String
    var eatenOut: Bool
    var hidden: Bool
    var special: Bool
    var spot: String
    var placeKey: String?
}

enum Backup {
    /// 写真の iCloud での ID を覚えておく（新しい端末では写真の ID が変わるので、これで見つけ直す）
    @MainActor
    static func fillCloudIDs(_ meal: Meal) {
        let ids = meal.photoIDs
        guard !ids.isEmpty, meal.cloudIDs.count != ids.count else { return }
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids)
        let cloud = ids.compactMap { id -> String? in
            guard case .success(let c)? = mappings[id] else { return nil }
            return c.stringValue
        }
        if cloud.count == ids.count { meal.cloudIDs = cloud }
    }

    /// 写真アプリで見つからない写真を、iCloud の ID から見つけ直す（新しい端末に移ったとき）。直した数を返す
    @MainActor
    static func remapMissing(context: ModelContext) -> Int {
        let meals = (try? context.fetch(FetchDescriptor<Meal>())) ?? []
        let broken = meals.filter { meal in
            guard let first = meal.photoIDs.first, !meal.cloudIDs.isEmpty else { return false }
            return PhotoLoader.asset(first) == nil
        }
        guard !broken.isEmpty else { return 0 }
        var fixed = 0
        for meal in broken.prefix(300) {
            let cloud = meal.cloudIDs.map { PHCloudIdentifier(stringValue: $0) }
            let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: cloud)
            let local = cloud.compactMap { c -> String? in
                guard case .success(let id)? = mappings[c] else { return nil }
                return id
            }
            if !local.isEmpty {
                meal.photoIDs = local
                fixed += 1
            }
        }
        try? context.save()
        return fixed
    }

    @MainActor
    static func make(context: ModelContext) -> BackupFile {
        let meals = (try? context.fetch(FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.date)]))) ?? []
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        return BackupFile(
            meals: meals.map { m in
                MealRecord(id: m.id, date: m.date, endDate: m.endDate, photoIDs: m.photoIDs, cloudIDs: m.cloudIDs,
                           latitude: m.latitude, longitude: m.longitude, area: m.area, region: m.region, genre: m.genre,
                           dishes: m.dishes, summary: m.summary, note: m.note, kind: m.kind, eatenOut: m.eatenOut,
                           hidden: m.hidden, special: m.special, spot: m.spot, placeKey: m.place?.key)
            },
            places: places.map { p in
                PlaceRecord(key: p.key, name: p.name, address: p.address, category: p.category, latitude: p.latitude,
                            longitude: p.longitude, wantAgain: p.wantAgain, note: p.note, firstVisit: p.firstVisit,
                            phone: p.phone, nextWish: p.nextWish, wantToTry: p.wantToTry)
            }
        )
    }

    /// 書き出したファイル（「ファイル」アプリの「このiPhone内 → ごはん帖」にも置く）
    @MainActor
    static func write(context: ModelContext) -> URL? {
        let file = make(context: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return nil }
        let url = URL.documentsDirectory.appendingPathComponent("ごはん帖のバックアップ.json")
        do {
            try data.write(to: url, options: .atomic)
            UserDefaults.standard.set(Date(), forKey: "backup.last")
            return url
        } catch {
            return nil
        }
    }

    /// 週に1回、自動で書き出す
    @MainActor
    static func autoWrite(context: ModelContext) {
        if let last = UserDefaults.standard.object(forKey: "backup.last") as? Date, last.timeIntervalSinceNow > -7 * 86_400 { return }
        _ = write(context: context)
    }

    static var lastWritten: Date? { UserDefaults.standard.object(forKey: "backup.last") as? Date }

    /// 読み戻す（同じ食事・お店はそのまま。足りないものだけ足す）。足した食事の数を返す
    @MainActor
    static func restore(from url: URL, context: ModelContext) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // 本人が選んだバックアップのファイル
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(BackupFile.self, from: data)
        var places: [String: Place] = [:]
        for p in (try? context.fetch(FetchDescriptor<Place>())) ?? [] { places[p.key] = p }
        for r in file.places where places[r.key] == nil {
            let candidate = PlaceCandidate(name: r.name, address: r.address, category: r.category, latitude: r.latitude,
                                           longitude: r.longitude, distance: 0, phone: r.phone)
            let place = Place(candidate: candidate, date: r.firstVisit)
            place.wantAgain = r.wantAgain
            place.note = r.note
            place.nextWish = r.nextWish
            place.wantToTry = r.wantToTry
            context.insert(place)
            places[r.key] = place
        }
        let existing = Set(((try? context.fetch(FetchDescriptor<Meal>())) ?? []).map(\.id))
        var added = 0
        for r in file.meals where !existing.contains(r.id) {
            let meal = Meal(date: r.date, endDate: r.endDate, photoIDs: r.photoIDs, latitude: r.latitude, longitude: r.longitude)
            meal.id = r.id
            meal.cloudIDs = r.cloudIDs
            meal.area = r.area
            meal.region = r.region
            meal.genre = r.genre
            meal.dishes = r.dishes
            meal.summary = r.summary
            meal.note = r.note
            meal.kind = r.kind
            meal.eatenOut = r.eatenOut
            meal.hidden = r.hidden
            meal.special = r.special
            meal.spot = r.spot
            meal.needsCheck = false
            meal.confidence = 1
            meal.source = "backup"
            if let key = r.placeKey { meal.place = places[key] }
            context.insert(meal)
            added += 1
        }
        try context.save()
        _ = remapMissing(context: context)
        return added
    }

    /// 表（CSV）に書き出す
    @MainActor
    static func csv(_ meals: [Meal]) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var text = "日時,お店,住所,ジャンル,料理,場所,また行きたい,メモ\n"
        for m in meals.sorted(by: { $0.date < $1.date }) {
            text += [f.string(from: m.date), m.title, m.place?.address ?? "", m.genre, m.dishText, m.area,
                     m.place?.wantAgain == true ? "○" : "", m.note].map(cell).joined(separator: ",") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ごはん帖.csv")
        // Excel で文字化けしないよう、先頭に BOM を付ける
        guard (try? (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// 写真つきの PDF（1 ページに 6 食）
    @MainActor
    static func pdf(_ meals: [Meal], title: String) async -> URL? {
        let sorted = meals.sorted { $0.date < $1.date }
        var thumbs: [UUID: UIImage] = [:]
        for m in sorted {
            if let id = m.photoIDs.first, let image = await ThumbCache.shared.image(id, side: 360) { thumbs[m.id] = image }
        }
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(title).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let ai = UIColor(hex: 0x22346B), hai = UIColor(hex: 0x586079)
        do {
            try renderer.writePDF(to: url) { context in
                for (i, m) in sorted.enumerated() {
                    if i % 6 == 0 {
                        context.beginPage()
                        (title as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: ai])
                    }
                    let y = 70 + CGFloat(i % 6) * 125
                    if let image = thumbs[m.id] {
                        image.draw(in: aspectFill(image.size, in: CGRect(x: 40, y: y, width: 110, height: 110)))
                    }
                    (m.title as NSString).draw(at: CGPoint(x: 165, y: y + 4), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 15), .foregroundColor: ai])
                    (f.string(from: m.date) as NSString).draw(at: CGPoint(x: 165, y: y + 28), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: hai])
                    let detail = "\(m.genre)・\(m.dishText)" + (m.note.isEmpty ? "" : "\n\(m.note)")
                    (detail as NSString).draw(in: CGRect(x: 165, y: y + 48, width: 390, height: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
                }
            }
            return url
        } catch {
            return nil
        }
    }

    private static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// 鍵を QR で渡す（便1）。6 桁の合言葉で鍵をかけてから QR にする
enum KeyHandoff {
    struct Payload: Codable {
        var key: String?
        var relayURL: String?
        var relayToken: String?
        var cap: Double
        /// 受け取った端末で費用を見せるか（便76）
        var showCost: Bool
    }

    static let prefix = "gohan-key:1:"

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    private static func symmetricKey(_ code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("gohan-handoff".utf8),
                               info: Data("v1".utf8), outputByteCount: 32)
    }

    static func seal(_ payload: Payload, code: String) -> String? {
        guard let data = try? JSONEncoder().encode(payload),
              let box = try? AES.GCM.seal(data, using: symmetricKey(code)), let combined = box.combined else { return nil }
        return prefix + combined.base64EncodedString()
    }

    static func open(_ text: String, code: String) -> Payload? {
        guard text.hasPrefix(prefix), let data = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: symmetricKey(code)) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: plain)
    }

    /// 受け取った中身を、この端末に入れる
    static func apply(_ payload: Payload) {
        if let key = payload.key, !key.isEmpty { KeyStore.claudeKey = key }
        if let url = payload.relayURL, !url.isEmpty, let token = payload.relayToken {
            AISettings.relayURL = url
            KeyStore.relayToken = token
        }
        Spend.cap = payload.cap
        AISettings.showCost = payload.showCost
        AISettings.deviceOnly = false
    }
}
