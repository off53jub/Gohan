import Foundation
import SwiftData

// 2026-11-28 Google マップのタイムライン（iPhone から書き出した Timeline.json）を、
// 「その時刻に自分がどこにいたか」の手がかりにする（大3）。
// - ういきょのごはんの取り込みで、自分も同じ所にいたかを確かめる（訪問の記録より昔まである）
// - 場所の無い自分の食事に、その時刻にいた所の位置を入れる（お店は「種類で探し直す」があとで探す）
// 中身は端末の中にだけ置く（外へは送らない）。

enum GoogleTimeline {
    struct Spot: Codable, Equatable {
        var start: Date
        var end: Date
        var latitude: Double
        var longitude: Double
        /// 滞在（visit）か、移動中の点か
        var stay: Bool
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("google-timeline.json")
    }

    static func load() -> [Spot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Spot].self, from: data)) ?? []
    }

    static func save(_ spots: [Spot]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(spots) { try? data.write(to: url, options: [.atomic, .completeFileProtection]) }
    }

    /// "geo:35.452706,139.391113" → (緯度, 経度)
    static func geo(_ s: String?) -> (Double, Double)? {
        guard let s, s.hasPrefix("geo:") else { return nil }
        let parts = s.dropFirst(4).split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return (lat, lon)
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// iPhone の Google マップの書き出し（semanticSegments の配列、または {"semanticSegments": [...]}）を読む
    static func parse(_ data: Data) -> [Spot] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let segments: [[String: Any]]
        if let list = json as? [[String: Any]] {
            segments = list
        } else if let dict = json as? [String: Any], let list = dict["semanticSegments"] as? [[String: Any]] {
            segments = list
        } else {
            return []
        }
        var out: [Spot] = []
        for s in segments {
            guard let start = date(s["startTime"] as? String), let end = date(s["endTime"] as? String) else { continue }
            if let visit = s["visit"] as? [String: Any], let top = visit["topCandidate"] as? [String: Any],
               let g = geo(top["placeLocation"] as? String) {
                out.append(Spot(start: start, end: end, latitude: g.0, longitude: g.1, stay: true))
            }
            if let path = s["timelinePath"] as? [[String: Any]] {
                for p in path {
                    guard let g = geo(p["point"] as? String) else { continue }
                    let offset = Double(p["durationMinutesOffsetFromStartTime"] as? String ?? "") ?? 0
                    let t = start.addingTimeInterval(offset * 60)
                    out.append(Spot(start: t, end: t, latitude: g.0, longitude: g.1, stay: false))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// 取り込みで使う形に分ける（滞在は訪問の記録と同じ扱い、移動中の点は自分の写真の場所と同じ扱い）
    static func visits(_ spots: [Spot]) -> [Visit] {
        spots.filter(\.stay).map { Visit(arrival: $0.start, departure: $0.end, latitude: $0.latitude, longitude: $0.longitude, accuracy: 50) }
    }

    static func points(_ spots: [Spot], from: Date, to: Date) -> [(date: Date, latitude: Double, longitude: Double)] {
        spots.filter { !$0.stay && $0.start >= from && $0.start <= to }.map { ($0.start, $0.latitude, $0.longitude) }
    }

    /// その時刻に滞在していた所（前後 10 分の余裕）
    static func stay(at date: Date, in spots: [Spot]) -> Spot? {
        let slack: TimeInterval = 10 * 60
        return spots.first { $0.stay && $0.start.addingTimeInterval(-slack) <= date && $0.end.addingTimeInterval(slack) >= date }
    }

    /// 場所の無い自分の食事に、その時刻に滞在していた所の位置を入れる。入れた数
    @MainActor
    static func fillMealLocations(_ spots: [Spot], context: ModelContext) async -> Int {
        let meals = (try? context.fetch(FetchDescriptor<Meal>())) ?? []
        var filled = 0
        for meal in meals where meal.latitude == nil && meal.place == nil && !meal.hidden && meal.spot.isEmpty {
            guard let s = stay(at: meal.date, in: spots) else { continue }
            meal.latitude = s.latitude
            meal.longitude = s.longitude
            let p = await PlaceFinder.areaAndRegion(latitude: s.latitude, longitude: s.longitude)
            if meal.area.isEmpty { meal.area = p.area }
            if meal.region.isEmpty { meal.region = p.region }
            meal.spot = Spots.which(latitude: s.latitude, longitude: s.longitude)
            if !meal.source.contains("+gtl") { meal.source += "+gtl" }
            filled += 1
            // 地名を調べる回数を抑える
            try? await Task.sleep(for: .seconds(1.2))
        }
        try? context.save()
        return filled
    }
}
