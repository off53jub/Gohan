import Foundation

// 精度を上げる手がかり（2026-11-24 本人「1234をやろう」）。どれも、ういちゃんの画面には出さず裏で使う。
// 1. iPhone の「訪問」の記録（どこに何分いたか）  2. お店の営業時間

/// iPhone が記録した「訪問」1回分。この iPhone の中だけに置く（AI には「何分いたか」だけを伝える）
struct Visit: Codable, Equatable {
    var arrival: Date?
    var departure: Date?
    var latitude: Double
    var longitude: Double
    var accuracy: Double

    /// いた時間（分）。来た時刻と出た時刻の両方が分かるときだけ
    var minutes: Int? {
        guard let arrival, let departure else { return nil }
        return Int((departure.timeIntervalSince(arrival) / 60).rounded())
    }
}

enum VisitLog {
    private static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("visits.json")
    }

    static func load() -> [Visit] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Visit].self, from: data)) ?? []
    }

    static func save(_ visits: [Visit]) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(visits) { try? data.write(to: url, options: .atomic) }
    }

    /// 訪問を足す。来たときと出たときの2回届くので、来た時刻が同じものは置きかえる。120 日より古いものは捨てる
    static func add(_ visit: Visit, to list: [Visit], now: Date = Date()) -> [Visit] {
        let line = now.addingTimeInterval(-120 * 86_400)
        var out = list.filter { ($0.departure ?? $0.arrival ?? now) > line }
        if let arrival = visit.arrival,
           let i = out.firstIndex(where: { old in old.arrival.map { abs($0.timeIntervalSince(arrival)) < 60 } ?? false }) {
            out[i] = visit
        } else {
            out.append(visit)
        }
        return out
    }

    /// 食事の時間（最初の写真〜最後の写真）にいた所。重なる訪問のうち、いちばん短いもの
    static func match(_ visits: [Visit], from: Date, to: Date, now: Date = Date()) -> Visit? {
        let slack: TimeInterval = 10 * 60
        let hits = visits.filter { v in
            guard let arrival = v.arrival else { return false }
            // 出た時刻がまだ届いていない訪問は、来てから 12 時間までしか使わない
            if v.departure == nil, from.timeIntervalSince(arrival) > 12 * 3600 { return false }
            let departure = v.departure ?? now
            return arrival <= from.addingTimeInterval(slack) && departure >= to.addingTimeInterval(-slack)
        }
        return hits.min { span($0, now: now) < span($1, now: now) }
    }

    private static func span(_ v: Visit, now: Date) -> TimeInterval {
        (v.departure ?? now).timeIntervalSince(v.arrival ?? now)
    }

    // MARK: - 訪問で食事を区切る（2026-11-26 案4）

    /// 2 枚の写真のあいだに、場所を移ったか
    enum Link: Equatable { case sameStay, moved, unknown }

    /// 家・職場・大きな建物のような長い滞在は、食事の区切りに使わない（中で何回も食べるかもしれない）
    static let longestStay: TimeInterval = 4 * 3600

    /// その時刻にいた所（重なる訪問のうち、いちばん短いもの）。前後 3 分はおまけする
    static func containing(_ visits: [Visit], date: Date, now: Date = Date()) -> Visit? {
        let slack: TimeInterval = 3 * 60
        let hits = visits.filter { v in
            guard let arrival = v.arrival else { return false }
            if v.departure == nil, date.timeIntervalSince(arrival) > 12 * 3600 { return false }
            let departure = v.departure ?? now
            return arrival <= date.addingTimeInterval(slack) && departure >= date.addingTimeInterval(-slack)
        }
        return hits.min { span($0, now: now) < span($1, now: now) }
    }

    /// 2 つの時刻が、同じ滞在の中か（sameStay）・別の所の滞在か（moved）・訪問の記録からは分からないか（unknown）
    static func link(_ visits: [Visit], _ a: Date, _ b: Date, now: Date = Date()) -> Link {
        guard !visits.isEmpty, let va = containing(visits, date: a, now: now), let vb = containing(visits, date: b, now: now) else {
            return .unknown
        }
        if va == vb {
            return span(va, now: now) <= longestStay ? .sameStay : .unknown
        }
        // 別の訪問でも、ほぼ同じ所（60m 以内）なら、記録が途中で切れただけかもしれないので決めつけない
        let apart = Matcher.distance(va.latitude, va.longitude, vb.latitude, vb.longitude)
        return apart > 60 ? .moved : .unknown
    }
}

extension Matcher {
    /// 写真の位置より訪問の位置を使うか（写真に位置が無い・ビルの中などで写真の位置があいまいなとき）
    static func useVisit(_ visit: Visit, spot: (latitude: Double, longitude: Double)?, accuracy: Double?) -> Bool {
        guard let spot else { return true }
        let acc = accuracy ?? 50
        guard acc > 65, visit.accuracy < acc else { return false }
        // 写真の位置と離れすぎていれば、別の所の訪問なので使わない
        return distance(spot.latitude, spot.longitude, visit.latitude, visit.longitude) <= max(300, acc * 3)
    }

    /// 写真を撮った時刻に閉まっていたはずのお店は、点数を下げる（消さない。営業時間の情報が古いこともある）
    static func applyHours(_ ranked: [PlaceCandidate], at date: Date, calendar: Calendar = .current) -> [PlaceCandidate] {
        ranked.map { c in
            var c = c
            if OpenHours.isOpen(hours: c.hours, closed: c.closedDays, at: date, calendar: calendar) == false {
                c.closedThen = true
                c.score = max(0, c.score - 0.3)
            }
            return c
        }
        .sorted { $0.score > $1.score }
    }
}

/// 営業時間（ホットペッパーの文・Google の決まった形）から、その時刻に開いていたかを見る
enum OpenHours {
    /// 開いていた → true、閉まっていた → false、分からない → nil。前後 30 分はおまけする
    static func isOpen(hours: String, closed: String, at date: Date, calendar: Calendar = .current) -> Bool? {
        if hours.hasPrefix("G|") { return google(String(hours.dropFirst(2)), at: date, calendar: calendar) }
        if closedOn(closed, at: date, calendar: calendar) { return false }
        let ranges = textRanges(hours)
        guard !ranges.isEmpty else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let t = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        for r in ranges {
            let lo = r.start - 30, hi = r.end + 30
            if (lo...hi).contains(t) || (lo...hi).contains(t + 1440) { return true }
        }
        return false
    }

    /// 「11:30～15:00」「17:00～翌2:00」「18:00～26:00」を分にする（翌・日またぎは 24 時間足す）
    static func textRanges(_ text: String) -> [(start: Int, end: Int)] {
        let pattern = #"(\d{1,2})[:：](\d{2})\s*[～〜~\-－ー‐]\s*(翌日?)?\s*(\d{1,2})[:：](\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [(start: Int, end: Int)] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func n(_ i: Int) -> Int { Int(ns.substring(with: m.range(at: i))) ?? 0 }
            let start = n(1) * 60 + n(2)
            var end = n(4) * 60 + n(5)
            if m.range(at: 3).location != NSNotFound { end += 1440 }
            if end <= start { end += 1440 }
            out.append((start, end))
        }
        return out
    }

    /// 定休日の文（「日曜日」「月・火」「日・祝」）に、その日の曜日が入っているか。不定休・第◯◯曜は見ない
    static func closedOn(_ text: String, at date: Date, calendar: Calendar = .current) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("不定"), !t.contains("第"), !t.contains("無休") else { return false }
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        let today = names[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
        if t.contains(today + "曜") { return true }
        // 「月」「月・火」「日・祝」のような短い書き方
        let rest = t.replacingOccurrences(of: "祝日", with: "").replacingOccurrences(of: "祝", with: "")
        let separators = CharacterSet(charactersIn: "・、,，/／ 　")
        let pieces = rest.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !pieces.isEmpty, pieces.allSatisfy({ names.contains($0) }) else { return false }
        return pieces.contains(today)
    }

    /// Google の営業時間（Places API の periods）を、候補に持たせる短い形にする: 「開いた曜日,時分,閉じた曜日,時分;…」
    static func googleText(_ periods: [[String: Any]]) -> String {
        func part(_ v: Any?) -> String? {
            guard let p = v as? [String: Any], let day = (p["day"] as? NSNumber)?.intValue else { return nil }
            let hour = (p["hour"] as? NSNumber)?.intValue ?? 0
            let minute = (p["minute"] as? NSNumber)?.intValue ?? 0
            return "\(day),\(hour * 60 + minute)"
        }
        let items = periods.compactMap { p -> String? in
            guard let open = part(p["open"]) else { return nil }
            // 閉じる時刻が無い = 24 時間開いている
            return open + "," + (part(p["close"]) ?? "-1,0")
        }
        return items.isEmpty ? "" : "G|" + items.joined(separator: ";")
    }

    private static func google(_ text: String, at date: Date, calendar: Calendar) -> Bool? {
        let weekday = (calendar.component(.weekday, from: date) - 1 + 7) % 7
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let t = weekday * 1440 + (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let week = 7 * 1440
        var any = false
        for item in text.split(separator: ";") {
            let n = item.split(separator: ",").compactMap { Int($0) }
            guard n.count == 4 else { continue }
            any = true
            if n[2] < 0 { return true }
            let start = n[0] * 1440 + n[1]
            var end = n[2] * 1440 + n[3]
            if end <= start { end += week }
            let lo = start - 30, hi = end + 30
            if (lo...hi).contains(t) || (lo...hi).contains(t + week) || (lo...hi).contains(t - week) { return true }
        }
        return any ? false : nil
    }
}
