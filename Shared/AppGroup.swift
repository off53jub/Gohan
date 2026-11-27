import Foundation

// アプリ・ホーム画面の小窓・共有ボタンの 3 つで使う、共通の置き場（大18・大19。2026-11-28）

enum AppGroup {
    static let id = "group.com.off53jub.gohan"
    static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// 小窓に出すもの（アプリが書き、小窓が読む）
struct WidgetFeedFile: Codable, Equatable {
    struct Memory: Codable, Equatable {
        var title: String
        var date: Date
        var mealID: String
        /// 置き場の中の写真のファイル名
        var image: String?
    }

    struct Want: Codable, Equatable {
        var name: String
        var detail: String
        var key: String
    }

    var made: Date
    var memory: Memory?
    var want: Want?

    static let fileName = "widget.json"
    static let imageName = "memory.jpg"

    static func read() -> WidgetFeedFile? {
        guard let url = AppGroup.folder?.appendingPathComponent(fileName), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetFeedFile.self, from: data)
    }

    func write() {
        guard let url = AppGroup.folder?.appendingPathComponent(Self.fileName) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// 共有ボタンから届いた文やリンク（共有の部品が足し、アプリが取り出す）
enum ShareInbox {
    static let fileName = "share-inbox.json"
    private static var url: URL? { AppGroup.folder?.appendingPathComponent(fileName) }

    static func add(_ text: String) {
        guard let url else { return }
        var all = read(url)
        all.append(text)
        if let data = try? JSONEncoder().encode(Array(all.suffix(20))) { try? data.write(to: url, options: .atomic) }
    }

    /// 届いた分を取り出して空にする
    static func take() -> [String] {
        guard let url else { return [] }
        let all = read(url)
        if !all.isEmpty { try? FileManager.default.removeItem(at: url) }
        return all
    }

    private static func read(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// ごはん帖を開くリンク（小窓から）
    static func mealURL(_ id: String) -> URL? { URL(string: "gohan://meal/\(id)") }
    static func placeURL(_ key: String) -> URL? {
        var c = URLComponents()
        c.scheme = "gohan"
        c.host = "place"
        c.queryItems = [URLQueryItem(name: "key", value: key)]
        return c.url
    }
}
