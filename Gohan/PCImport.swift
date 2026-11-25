import CryptoKit
import Foundation
import Photos
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// PC から取り込む（作る人のメニューだけ。2026-11-25）
// pCloud や Google フォトの写真を PC で下ごしらえし（ご飯か・料理の名前・看板の店名は PC の Claude が見る）、
// できたファイルをここで読む。このアプリの AI は呼ばない。お店は、地図とホットペッパー（無料）だけで探す。
// 道具は tools/photo-import/（README を参照）。

struct ImportFile: Codable {
    var kind = "gohan.import"
    var version = 1
    var made = Date()
    /// どこの写真か（"pCloud"・"Google フォト" など。表示だけ）
    var source = ""
    var meals: [ImportMeal]
}

struct ImportMeal: Codable, Equatable {
    var date: Date
    var endDate: Date
    var latitude: Double?
    var longitude: Double?
    var accuracy: Double?
    /// PC の Claude が写真を見て決めたこと（お店の番号は分からないので -1）
    var verdict: MealVerdict
    /// 看板・メニュー・レシートから読めた文字（お店の候補の点数に使う）
    var lines: [String] = []
    var photos: [ImportPhoto]
    /// PC の Claude が、場所の近くのお店（OpenStreetMap）と写真から選んだお店（無ければ nil）
    var place: ImportPlace? = nil
}

struct ImportPlace: Codable, Equatable {
    var name: String
    var latitude: Double?
    var longitude: Double?
    var confidence: Double
    var reason: String
}

struct ImportPhoto: Codable, Equatable {
    /// 撮った時刻（この iPhone の写真アプリに同じ写真があれば、そちらを使う）
    var date: Date
    /// 長い辺 1280px くらいの JPEG
    var jpeg: Data
}

/// 取り込んだ写真（写真アプリに無いもの）を、アプリの中に置く。ID は "file:〇〇.jpg"
enum ImportedPhotos {
    static let prefix = "file:"

    static var folder: URL { URL.applicationSupportDirectory.appendingPathComponent("imported", isDirectory: true) }

    static func isFile(_ id: String) -> Bool { id.hasPrefix(prefix) }

    static func url(_ id: String) -> URL? {
        guard isFile(id) else { return nil }
        let name = String(id.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return folder.appendingPathComponent(name)
    }

    static func save(_ jpeg: Data) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
            return prefix + name
        } catch {
            return nil
        }
    }

    /// 長い辺が side くらいの絵
    static func image(_ id: String, side: CGFloat) async -> UIImage? {
        guard let url = url(id) else { return nil }
        return await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, Int(side)),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
    }

    /// 中身の指紋（同じ写真を 2 回入れないため。PC は同じ写真から毎回同じ JPEG を作る）
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of id: String) -> String? {
        guard let url = url(id), let data = try? Data(contentsOf: url) else { return nil }
        return digest(data)
    }
}

enum PCImport {
    struct Result: Equatable {
        var added = 0
        var skipped = 0
        var notMeal = 0
        var fromLibrary = 0
        var fromFile = 0
        /// PC から前に入れた食事に、写真を足した数・ジャンルを直した数（入れ直したとき）
        var photosAdded = 0
        var genresFixed = 0
    }

    static func decode(_ data: Data) throws -> ImportFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        let file = try decoder.decode(ImportFile.self, from: data)
        guard file.kind == "gohan.import" else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }

    /// もう記録にある食事か（前後 45 分・300m 以内。位置の分からないほうがあれば時刻だけで見る）
    static func isDuplicate(_ meal: ImportMeal, existing: [(date: Date, latitude: Double?, longitude: Double?)]) -> Bool {
        matchIndex(meal, existing: existing) != nil
    }

    /// 同じ食事の番号（いちばん時刻の近いもの）
    static func matchIndex(_ meal: ImportMeal, existing: [(date: Date, latitude: Double?, longitude: Double?)]) -> Int? {
        existing.indices.filter { i in
            let e = existing[i]
            guard abs(e.date.timeIntervalSince(meal.date)) <= 45 * 60 else { return false }
            guard let a = meal.latitude, let b = meal.longitude, let c = e.latitude, let d = e.longitude else { return true }
            return Matcher.distance(a, b, c, d) <= 300
        }
        .min { abs(existing[$0].date.timeIntervalSince(meal.date)) < abs(existing[$1].date.timeIntervalSince(meal.date)) }
    }

    /// 写真アプリに同じ写真（撮った時刻が 2 秒以内）があれば、その ID
    static func libraryMatch(_ date: Date) -> String? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                                        PHAssetMediaType.image.rawValue,
                                        date.addingTimeInterval(-2) as NSDate, date.addingTimeInterval(2) as NSDate)
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).firstObject?.localIdentifier
    }
}

extension Scanner {
    /// PC で作ったファイルを読み、食事にする。このアプリの AI は呼ばない
    func importFromPC(_ file: ImportFile, context: ModelContext, progress: (String) -> Void) async -> PCImport.Result {
        var result = PCImport.Result()
        let current = (try? context.fetch(FetchDescriptor<Meal>())) ?? []
        refreshDishBook(current)
        var known = current
        var existing = current.map { (date: $0.date, latitude: $0.latitude, longitude: $0.longitude) }
        var seen = SeenStore.load()
        let meals = file.meals.sorted { $0.date < $1.date }
        // Apple のマップの検索は 1 分に約 50 回まで（超えると黙って空が返り、お店が決まらない）。
        // PC からの食事は名前の検索をしないので 1 食あたり 1〜2 回。食事が多いファイルは 1 食に 3 秒ずつかけて、超えないようにする
        let paced = meals.count > 20
        let pace: TimeInterval = 3
        for (i, item) in meals.enumerated() {
            if Task.isCancelled { break }
            let left = paced ? Int((Double(meals.count - i) * pace / 60).rounded(.up)) : 0
            progress("\(i + 1)/\(meals.count)" + (left > 1 ? "（あと約 \(left) 分）" : ""))
            if !item.verdict.is_meal { result.notMeal += 1; continue }
            if let index = PCImport.matchIndex(item, existing: existing) {
                // もうある食事。PC から前に入れたものなら、足りない写真を足し、ジャンルを新しい答えにする（本人が直したジャンルは残す）
                let meal = known[index]
                if meal.source.hasPrefix("pc") {
                    let changed = refreshFromPC(meal, with: item, seen: &seen)
                    result.photosAdded += changed.photos
                    if changed.genre { result.genresFixed += 1 }
                } else {
                    result.skipped += 1
                }
                if i % 20 == 19 { try? context.save() }
                continue
            }
            var group: [SeenPhoto] = []
            for photo in item.photos.sorted(by: { $0.date < $1.date }) {
                let id: String
                if let local = PCImport.libraryMatch(photo.date), group.allSatisfy({ $0.id != local }) {
                    id = local
                    result.fromLibrary += 1
                } else if let saved = ImportedPhotos.save(photo.jpeg) {
                    id = saved
                    result.fromFile += 1
                } else {
                    continue
                }
                let seenPhoto = SeenPhoto(id: id, date: photo.date, latitude: item.latitude, longitude: item.longitude,
                                          accuracy: item.accuracy, food: 1, label: "", used: true)
                group.append(seenPhoto)
                // 写真アプリの写真なら、ふだんの読み取りでもう一度食事にしないよう「使った」にしておく
                if !ImportedPhotos.isFile(id) { seen[id] = seenPhoto }
            }
            guard !group.isEmpty else { continue }
            let started = Date()
            if let meal = await buildMeal(group, all: [], context: context, old: true, preset: item.verdict, presetLines: item.lines,
                                          presetPlace: item.place) {
                meal.endDate = max(meal.endDate, item.endDate)
                existing.append((date: meal.date, latitude: meal.latitude, longitude: meal.longitude))
                known.append(meal)
                result.added += 1
                Metrics.count("pcImports")
            }
            if i % 10 == 9 { try? context.save() }
            let wait = pace - Date().timeIntervalSince(started)
            if paced, wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        SeenStore.save(seen)
        try? context.save()
        return result
    }

    /// PC から前に入れた食事を、新しいファイルの中身で直す（写真を足す・ジャンルを直す）。地図も AI も呼ばない
    func refreshFromPC(_ meal: Meal, with item: ImportMeal, seen: inout [String: SeenPhoto]) -> (photos: Int, genre: Bool) {
        var prints = Set(meal.photoIDs.compactMap { ImportedPhotos.digest(of: $0) })
        var added = 0
        for photo in item.photos.sorted(by: { $0.date < $1.date }) {
            if let local = PCImport.libraryMatch(photo.date) {
                guard !meal.photoIDs.contains(local) else { continue }
                meal.photoIDs.append(local)
                seen[local] = SeenPhoto(id: local, date: photo.date, latitude: item.latitude, longitude: item.longitude,
                                        accuracy: item.accuracy, food: 1, label: "", used: true)
                added += 1
                continue
            }
            let fingerprint = ImportedPhotos.digest(photo.jpeg)
            guard !prints.contains(fingerprint), let saved = ImportedPhotos.save(photo.jpeg) else { continue }
            prints.insert(fingerprint)
            meal.photoIDs.append(saved)
            added += 1
        }
        var genre = false
        if !meal.genreByHand, item.verdict.is_meal, meal.genre != item.verdict.genre {
            meal.genre = item.verdict.genre
            meal.dishes = Matcher.canonicalDishes(item.verdict.dishes.filter { !$0.isEmpty }, book: dishBook)
            meal.summary = item.verdict.summary
            meal.kind = item.verdict.kind
            genre = true
        }
        return (added, genre)
    }
}

/// 作る人のメニュー →「PC から取り込む」
struct PCImportView: View {
    @Environment(\.modelContext) private var context
    @State private var picking = false
    @State private var running = false
    @State private var progress = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button {
                    picking = true
                } label: {
                    Label("ファイルを選ぶ", systemImage: "square.and.arrow.down")
                }
                .disabled(running)
                if running {
                    HStack {
                        ProgressView()
                        Text("取り込んでいます \(progress)").foregroundStyle(.secondary)
                    }
                }
                if let message { Text(message) }
            } footer: {
                Text("PC の道具（tools/photo-import）で作った「ごはん帖の取り込み」のファイルを選びます。料理の名前や看板の店名は PC で読んであるので、このアプリの AI は使いません（お金はかかりません）。お店は地図とホットペッパーで探します。もう記録にある食事は足しません。食事の多いファイルは 1 食に 3 秒ずつかけます（地図の検索の回数の上限のため）。取り込みの間はこの画面のままにしてください。")
            }
            Section {
                LabeledContent("今月 取り込んだ食事", value: "\(Metrics.value("pcImports"))")
                LabeledContent("アプリの中に置いた写真", value: "\(ImportedPhotos.count) 枚")
            }
        }
        .navigationTitle("PC から取り込む")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .data], allowsMultipleSelection: true) { picked in
            guard case .success(let urls) = picked else { return }
            Task { await run(urls) }
        }
    }

    private func run(_ urls: [URL]) async {
        running = true
        // 食事が多いと何十分もかかる。画面が消えるとアプリが止まるので、取り込みの間は消さない
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        var total = PCImport.Result()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try PCImport.decode(try Data(contentsOf: url))
                let r = await Scanner.shared.importFromPC(file, context: context) { progress = $0 }
                total.added += r.added
                total.skipped += r.skipped
                total.notMeal += r.notMeal
                total.fromLibrary += r.fromLibrary
                total.fromFile += r.fromFile
                total.photosAdded += r.photosAdded
                total.genresFixed += r.genresFixed
            } catch {
                message = "読めませんでした（\(url.lastPathComponent)）"
                return
            }
        }
        message = "\(total.added) 食を足しました（もうあった \(total.skipped)・食事ではない \(total.notMeal)）。写真は 写真アプリから \(total.fromLibrary) 枚・ファイルから \(total.fromFile) 枚。"
            + (total.photosAdded + total.genresFixed > 0
               ? "前に入れた食事に写真を \(total.photosAdded) 枚足し、ジャンルを \(total.genresFixed) 件直しました。" : "")
    }
}
