import Foundation

/// 外れ方の記録（1。2026-11-24）。直したとき・「合ってる」を押したときに、自動で1行残す。
/// 正しいお店が「候補に入っていたのに選び間違えた」のか「そもそも候補に無かった」のかで、打つ手が変わるため。
struct AccuracyEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// "hit"（合ってた）・"place"（お店を直した）・"notShop"（お店ではなかった）・"genre"（ジャンルを直した）
    var kind: String
    /// 決め方（claude・device・known・batch など）
    var source: String
    /// 正しいお店が候補の何番目にあったか（0 から。無かったら -1。お店でないときは -2）
    var rank: Int = -2
    /// 写真の判定のいちばん強い名前
    var label: String = ""
    var before: String = ""
    var after: String = ""
}

enum AccuracyLog {
    private static var url: URL { URL.applicationSupportDirectory.appendingPathComponent("accuracy-log.json") }

    static func load() -> [AccuracyEntry] {
        // 自分で保存したファイル
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AccuracyEntry].self, from: data)) ?? []
    }

    static func add(_ entry: AccuracyEntry) {
        var all = load()
        all.append(entry)
        if all.count > 2000 { all.removeFirst(all.count - 2000) }
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    /// お店を直したとき（正しいお店が、元の候補の何番目だったか）
    static func placeFixed(_ meal: Meal, to right: PlaceCandidate, oldName: String?) {
        let n = Matcher.normalize(right.name)
        let rank = meal.candidates.firstIndex { $0.key == right.key || Matcher.normalize($0.name) == n } ?? -1
        add(AccuracyEntry(kind: "place", source: meal.source, rank: rank, label: meal.visionLabel, before: oldName ?? "", after: right.name))
    }

    static func notShop(_ meal: Meal) {
        add(AccuracyEntry(kind: "notShop", source: meal.source, label: meal.visionLabel, before: meal.place?.name ?? ""))
    }

    static func hit(_ meal: Meal) {
        add(AccuracyEntry(kind: "hit", source: meal.source, rank: 0, label: meal.visionLabel, before: meal.place?.name ?? "", after: meal.place?.name ?? ""))
    }

    static func genreFixed(_ meal: Meal, from old: String, to new: String) {
        add(AccuracyEntry(kind: "genre", source: meal.source, label: meal.visionLabel, before: old, after: new))
    }

    struct Summary: Equatable {
        var hits = 0
        var fixedInList = 0
        var fixedNotInList = 0
        var notShop = 0
        var genreFixed = 0
        var genreFromPhoto = 0
    }

    static func summary(_ entries: [AccuracyEntry]) -> Summary {
        var s = Summary()
        for e in entries {
            switch e.kind {
            case "hit": s.hits += 1
            case "place": if e.rank >= 0 { s.fixedInList += 1 } else { s.fixedNotInList += 1 }
            case "notShop": s.notShop += 1
            case "genre":
                s.genreFixed += 1
                if e.source == "device" || e.source == "known" { s.genreFromPhoto += 1 }
            default: break
            }
        }
        return s
    }

    /// 送れる形（本人が Claude に見せて、次の手を決めるため）
    static func exportURL() -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(load()) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ごはん帖の当たり具合.json")
        return (try? data.write(to: out, options: .atomic)) == nil ? nil : out
    }
}
