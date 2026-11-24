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
}

enum PCImport {
    struct Result: Equatable {
        var added = 0
        var skipped = 0
        var notMeal = 0
        var fromLibrary = 0
        var fromFile = 0
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
        existing.contains { e in
            guard abs(e.date.timeIntervalSince(meal.date)) <= 45 * 60 else { return false }
            guard let a = meal.latitude, let b = meal.longitude, let c = e.latitude, let d = e.longitude else { return true }
            return Matcher.distance(a, b, c, d) <= 300
        }
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
        var existing = current.map { (date: $0.date, latitude: $0.latitude, longitude: $0.longitude) }
        var seen = SeenStore.load()
        let meals = file.meals.sorted { $0.date < $1.date }
        for (i, item) in meals.enumerated() {
            if Task.isCancelled { break }
            progress("\(i + 1)/\(meals.count)")
            if !item.verdict.is_meal { result.notMeal += 1; continue }
            if PCImport.isDuplicate(item, existing: existing) { result.skipped += 1; continue }
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
            if let meal = await buildMeal(group, all: [], context: context, old: true, preset: item.verdict, presetLines: item.lines) {
                meal.endDate = max(meal.endDate, item.endDate)
                existing.append((date: meal.date, latitude: meal.latitude, longitude: meal.longitude))
                result.added += 1
                Metrics.count("pcImports")
            }
            if i % 10 == 9 { try? context.save() }
        }
        SeenStore.save(seen)
        try? context.save()
        return result
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
                Text("PC の道具（tools/photo-import）で作った「ごはん帖の取り込み」のファイルを選びます。料理の名前や看板の店名は PC で読んであるので、このアプリの AI は使いません（お金はかかりません）。お店は地図とホットペッパーで探します。もう記録にある食事は足しません。")
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
        defer { running = false }
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
            } catch {
                message = "読めませんでした（\(url.lastPathComponent)）"
                return
            }
        }
        message = "\(total.added) 食を足しました（もうあった \(total.skipped)・食事ではない \(total.notMeal)）。写真は 写真アプリから \(total.fromLibrary) 枚・ファイルから \(total.fromFile) 枚。"
    }
}
