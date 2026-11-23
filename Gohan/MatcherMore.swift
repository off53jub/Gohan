import Foundation

// 2026-11-23 に足した決め方（通信も画面も使わないので、テストで確かめる）
extension Matcher {
    // MARK: - かんたんな食事（便11・便12）

    /// 前に行ったお店が、ほかより十分に強い（AI にお店を聞かなくてよい）
    static func knownPlace(_ ranked: [PlaceCandidate]) -> PlaceCandidate? {
        guard let top = ranked.first, top.visited, top.distance <= 80 else { return nil }
        let second = ranked.dropFirst().first?.score ?? 0
        return top.score - second >= 0.15 || top.textHit >= 0.9 ? top : nil
    }

    /// 看板の文字で店名がはっきり読めていて、2位との差も大きい（軽いモデルで足りる）
    static func isEasy(_ ranked: [PlaceCandidate]) -> Bool {
        guard let top = ranked.first, top.textHit >= 0.9 else { return false }
        let second = ranked.dropFirst().first?.score ?? 0
        return top.score - second >= 0.25
    }

    // MARK: - 理由の1行（デ10）

    static func reason(for pick: PlaceCandidate?, source: String, receipt: Bool) -> String {
        guard let pick else { return "" }
        if pick.textHit >= 0.9 {
            let name = coreName(pick.name)
            return receipt ? "レシートの文字「\(name)」と場所が合いました" : "看板の文字「\(name)」と場所が合いました"
        }
        if pick.visited { return "前にも来たお店で、場所が合いました" }
        if source == "device" { return "写真の場所にいちばん近いお店です（\(Int(pick.distance.rounded()))m）" }
        return ""
    }

    // MARK: - 料理名のゆれ（便27）

    /// らーめん／ラーメン、ｶﾚｰ／カレー などを同じとみなす印
    static func dishKey(_ dish: String) -> String {
        let kata = dish.applyingTransform(.hiraganaToKatakana, reverse: false) ?? dish
        return normalize(kata).replacingOccurrences(of: "ー", with: "")
    }

    /// 同じ印の書き方のうち、いちばん多いものにそろえる
    static func canonicalDishes(_ dishes: [String], book: [String: String]) -> [String] {
        var out: [String] = []
        for dish in dishes {
            let canonical = book[dishKey(dish)] ?? dish
            if !out.contains(canonical) { out.append(canonical) }
        }
        return out
    }

    /// 料理名の帳面を作る（印 → いちばん多い書き方）
    static func dishBook(_ all: [[String]]) -> [String: String] {
        var count: [String: [String: Int]] = [:]
        for dishes in all {
            for dish in dishes { count[dishKey(dish), default: [:]][dish, default: 0] += 1 }
        }
        return count.compactMapValues { $0.max { $0.value < $1.value }?.key }
    }

    // MARK: - 直したら覚える（便51）

    /// 場所（だいたい 100m 四方）の印
    static func spotKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.3f|%.3f", latitude, longitude)
    }

    /// 覚えた直しを点数に当てる: 正しいと直されたお店は上へ、違うと直されたお店は下へ
    static func applyCorrections(_ ranked: [PlaceCandidate], right: Set<String>, wrong: Set<String>) -> [PlaceCandidate] {
        ranked.map { c in
            var c = c
            if right.contains(normalize(c.name)) { c.score = min(1, c.score + 0.5) }
            if wrong.contains(normalize(c.name)) { c.score = max(0, c.score - 0.5) }
            return c
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - 旅行のまとまり（便20）

    struct TripSpan: Equatable {
        var region: String
        var start: Date
        var end: Date
        var mealIDs: [UUID]
    }

    struct TripInput {
        var id: UUID
        var date: Date
        var latitude: Double?
        var longitude: Double?
        var region: String
    }

    /// おうちから 50km 以上離れた食事が、続いた日（あいだ 1 日まで）にあれば、旅行として1つにまとめる
    static func trips(_ meals: [TripInput], home: (latitude: Double, longitude: Double)?, minMeals: Int = 2) -> [TripSpan] {
        guard let home else { return [] }
        let away = meals
            .filter { m in
                guard let lat = m.latitude, let lon = m.longitude else { return false }
                return distance(lat, lon, home.latitude, home.longitude) >= 50_000
            }
            .sorted { $0.date < $1.date }
        var spans: [TripSpan] = []
        for m in away {
            if var last = spans.last, m.date.timeIntervalSince(last.end) <= 2 * 86_400 {
                last.end = m.date
                last.mealIDs.append(m.id)
                if last.region.isEmpty { last.region = m.region }
                spans[spans.count - 1] = last
            } else {
                spans.append(TripSpan(region: m.region, start: m.date, end: m.date, mealIDs: [m.id]))
            }
        }
        return spans.filter { $0.mealIDs.count >= minMeals }
    }

    // MARK: - 今日のおすすめ（便42）

    /// 近いほど・ごぶさたなほど高い。行ってみたいだけのお店は少し上乗せ
    static func pickScore(distance: Double?, daysSince: Double?, notYet: Bool) -> Double {
        let near = distance.map { exp(-$0 / 1500) } ?? 0.3
        let away = min(1, (daysSince ?? 120) / 180)
        return near * 0.6 + away * 0.3 + (notYet ? 0.1 : 0)
    }
}
