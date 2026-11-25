import Foundation

/// 写真1枚の、端末で見た結果（写真アプリの写真ごとに1つ覚えておく）
struct SeenPhoto: Codable, Equatable {
    var id: String
    var date: Date
    var latitude: Double?
    var longitude: Double?
    var accuracy: Double?
    /// 食べ物らしさ（0〜1）
    var food: Double
    /// いちばん強い食べ物のラベル（Vision の英語の名前）
    var label: String
    /// もう食事にまとめたか
    var used: Bool = false
    /// 動画から拾った1コマか（便21）
    var isVideo: Bool = false
    /// カメラで撮った写真ではない（SNS から保存した画像など。便22）
    var noCamera: Bool = false
    /// 食べ物の上位の名前と強さ（ジャンルを見分けるため。2026-11-24）
    var labels: [String: Double] = [:]

    init(id: String, date: Date, latitude: Double?, longitude: Double?, accuracy: Double?, food: Double, label: String,
         used: Bool = false, isVideo: Bool = false, noCamera: Bool = false, labels: [String: Double] = [:]) {
        self.id = id
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.food = food
        self.label = label
        self.used = used
        self.isVideo = isVideo
        self.noCamera = noCamera
        self.labels = labels
    }

    // 前の版で覚えた写真（isVideo・noCamera が無い）も読めるように
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        accuracy = try c.decodeIfPresent(Double.self, forKey: .accuracy)
        food = try c.decodeIfPresent(Double.self, forKey: .food) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        used = try c.decodeIfPresent(Bool.self, forKey: .used) ?? false
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        noCamera = try c.decodeIfPresent(Bool.self, forKey: .noCamera) ?? false
        labels = try c.decodeIfPresent([String: Double].self, forKey: .labels) ?? [:]
    }
}

/// 通信も画面も使わない決め方（テストできるように、ここにまとめる）
enum Matcher {
    /// 食べ物とみなす強さ（仮。外れが多ければ上げる）
    static let foodThreshold = 0.3
    /// 同じ食事とみなす写真の間（秒）と距離（m）
    static let mealGap: TimeInterval = 40 * 60
    static let mealDistance = 250.0
    /// 同じ場所（100m 以内）なら、間が 90 分あいても同じ食事（飲み会・コースが 2 つに割れないように。2026-11-25）
    static let longMealGap: TimeInterval = 90 * 60
    static let sameSpotDistance = 100.0
    /// 撮ってからこの長さは待つ（食べている途中で区切らないため）
    static let holdBack: TimeInterval = 60 * 60
    /// この自信より低ければ「たぶん」の印を付ける
    static let sureLine = 0.7

    // MARK: - 写真を食事にまとめる

    static func groupMeals(_ photos: [SeenPhoto]) -> [[SeenPhoto]] {
        let sorted = photos.sorted { $0.date < $1.date }
        var groups: [[SeenPhoto]] = []
        for photo in sorted {
            if var last = groups.last, let tail = last.last,
               photo.date.timeIntervalSince(tail.date) <= (sameSpot(photo, last) ? longMealGap : mealGap),
               closeEnough(photo, last),
               !courseChanged(from: tail, to: photo) {
                last.append(photo)
                groups[groups.count - 1] = last
            } else {
                groups.append([photo])
            }
        }
        return groups
    }

    /// カフェ → ごはん のように、甘いもの・飲み物と食事が 20 分以上あけて入れかわったら別の食事にする（便19）
    static func courseChanged(from a: SeenPhoto, to b: SeenPhoto) -> Bool {
        guard b.date.timeIntervalSince(a.date) >= 20 * 60, !a.label.isEmpty, !b.label.isEmpty else { return false }
        return isLight(a.label) != isLight(b.label)
    }

    static let lightLabels: Set<String> = [
        "dessert", "cake", "coffee", "tea", "pastry", "ice_cream", "cookie", "donut", "cupcake", "candy", "chocolate",
        "macaron", "parfait", "crepe", "juice", "smoothie", "drink", "beverage", "beer", "wine", "cocktail",
    ]

    static func isLight(_ label: String) -> Bool { lightLabels.contains(label) }

    /// 位置の無い写真に、前後 30 分以内に撮った写真の位置を借りる（便16）
    static func fillLocations(_ photos: [SeenPhoto], among all: [SeenPhoto]) -> [SeenPhoto] {
        let located = all.filter { $0.latitude != nil && $0.longitude != nil }
        return photos.map { photo in
            guard photo.latitude == nil else { return photo }
            let near = located.filter { abs($0.date.timeIntervalSince(photo.date)) <= 30 * 60 }
            guard let best = near.min(by: { abs($0.date.timeIntervalSince(photo.date)) < abs($1.date.timeIntervalSince(photo.date)) }) else {
                return photo
            }
            var p = photo
            p.latitude = best.latitude
            p.longitude = best.longitude
            p.accuracy = max(best.accuracy ?? 50, 100)
            return p
        }
    }

    /// 写真にも食事にも位置があり、100m 以内か（位置の分からないときは「同じ場所」とみなさない）
    private static func sameSpot(_ photo: SeenPhoto, _ group: [SeenPhoto]) -> Bool {
        guard let lat = photo.latitude, let lon = photo.longitude, let center = center(of: group) else { return false }
        return distance(lat, lon, center.latitude, center.longitude) <= sameSpotDistance
    }

    /// 食事のあいだに同じ場所で撮った、料理ではない写真（人・お店の中・外観など。思い出として食事に入れる。2026-11-25）
    /// 料理の写真がない時間・ほかの場所の写真・SNS から保存した画像は入れない
    static func companionPhotos(for meal: [SeenPhoto], among all: [SeenPhoto], limit: Int = 12) -> [SeenPhoto] {
        guard let first = meal.first?.date, let last = meal.last?.date else { return [] }
        let ids = Set(meal.map(\.id))
        let spot = center(of: meal)
        let window = (first.addingTimeInterval(-5 * 60))...(last.addingTimeInterval(5 * 60))
        let hits = all.filter { photo in
            guard !ids.contains(photo.id), !photo.noCamera, window.contains(photo.date) else { return false }
            guard let spot else { return true }
            guard let lat = photo.latitude, let lon = photo.longitude else { return true }
            return distance(lat, lon, spot.latitude, spot.longitude) <= 150
        }
        return Array(hits.sorted { $0.date < $1.date }.prefix(limit))
    }

    private static func closeEnough(_ photo: SeenPhoto, _ group: [SeenPhoto]) -> Bool {
        guard let lat = photo.latitude, let lon = photo.longitude else { return true }
        guard let center = center(of: group) else { return true }
        return distance(lat, lon, center.latitude, center.longitude) <= mealDistance
    }

    /// 位置のある写真の真ん中（中央値なので、1枚だけずれていても引っぱられない）
    static func center(of photos: [SeenPhoto]) -> (latitude: Double, longitude: Double)? {
        let lats = photos.compactMap(\.latitude).sorted()
        let lons = photos.compactMap(\.longitude).sorted()
        guard !lats.isEmpty, lats.count == lons.count else { return nil }
        return (lats[lats.count / 2], lons[lons.count / 2])
    }

    /// 食事の前後に撮った、食べ物ではない写真（看板・メニュー・レシートかもしれない）
    static func cluePhotos(for meal: [SeenPhoto], among all: [SeenPhoto], limit: Int = 4) -> [SeenPhoto] {
        guard let first = meal.first?.date, let last = meal.last?.date else { return [] }
        let ids = Set(meal.map(\.id))
        let spot = center(of: meal)
        let window = (first.addingTimeInterval(-20 * 60))...(last.addingTimeInterval(20 * 60))
        let hits = all.filter { photo in
            guard !ids.contains(photo.id), photo.food < foodThreshold, window.contains(photo.date) else { return false }
            if let spot, let lat = photo.latitude, let lon = photo.longitude {
                return distance(lat, lon, spot.latitude, spot.longitude) <= 300
            }
            return true
        }
        // 食事の始まりに近いものから（入る前の看板・席でのメニュー）
        return Array(hits.sorted { abs($0.date.timeIntervalSince(first)) < abs($1.date.timeIntervalSince(first)) }.prefix(limit))
    }

    // MARK: - 距離

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - 文字の比べ方

    /// 全角・半角、大文字・小文字、空白と記号の違いをならす
    static func normalize(_ text: String) -> String {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let lower = half.lowercased()
        var out = ""
        for scalar in lower.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// 2つの文字の近さ（0〜1）。片方がもう片方に入っていれば 1
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        guard x.count >= 2, y.count >= 2 else { return x == y && !x.isEmpty ? 1 : 0 }
        if x.contains(y) || y.contains(x) { return 1 }
        let gx = bigrams(x), gy = bigrams(y)
        guard !gx.isEmpty, !gy.isEmpty else { return 0 }
        let common = gx.intersection(gy).count
        return 2 * Double(common) / Double(gx.count + gy.count)
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) { out.insert(String(chars[i...i + 1])) }
        return out
    }

    /// 写真の文字のどこかに、お店の名前が出ているか（0〜1）
    static func textMatch(name: String, lines: [String]) -> Double {
        let core = coreName(name)
        var best = 0.0
        for line in lines {
            best = max(best, similarity(core, line))
            if best >= 1 { break }
        }
        return best
    }

    /// 「麺屋 ○○ 新宿店」→「麺屋 ○○」（支店名は看板に出ないことが多い）
    static func coreName(_ name: String) -> String {
        var parts = name.split(separator: " ").map(String.init)
        if parts.count > 1, let last = parts.last, last.hasSuffix("店") { parts.removeLast() }
        return parts.joined(separator: " ")
    }

    /// レシート・領収書らしい文字か（便18）
    static func looksLikeReceipt(_ lines: [String]) -> Bool {
        let joined = lines.joined(separator: " ")
        let hints = ["領収", "レシート", "合計", "小計", "お預り", "お釣", "TEL", "Tel", "電話", "登録番号"]
        return hints.filter { joined.contains($0) }.count >= 2
    }

    /// レシートの上のほうに書いてある店名らしい行（レシートでなければ空）
    static func receiptNames(_ lines: [String]) -> [String] {
        guard looksLikeReceipt(lines) else { return [] }
        let skip = ["領収", "レシート", "合計", "小計", "様", "円", "¥", "TEL", "Tel", "電話", "登録番号", "No", "税"]
        var out: [String] = []
        for line in lines.prefix(8) {
            let n = normalize(line)
            guard n.count >= 2, n.count <= 20, !skip.contains(where: { line.contains($0) }) else { continue }
            if Double(n.filter(\.isNumber).count) / Double(n.count) > 0.3 { continue }
            out.append(line)
            if out.count >= 2 { break }
        }
        return out
    }

    /// 地図で探すのに使えそうな文字（店名らしい行）。値段・日付・短すぎる・長すぎるものは外す
    static func searchableLines(_ lines: [String], limit: Int = 3) -> [String] {
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = normalize(line)
            guard n.count >= 2, n.count <= 16 else { continue }
            let digits = n.filter(\.isNumber).count
            if Double(digits) / Double(n.count) > 0.3 { continue }
            if line.contains("円") || line.contains("¥") || line.contains("税") || line.contains("合計") { continue }
            if out.contains(where: { normalize($0) == n }) { continue }
            out.append(line)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - お店の点数

    /// 距離・写真の文字・前に行ったか・種類で点を付け、高い順に並べる
    static func rank(_ candidates: [PlaceCandidate], lines: [String], dishLabel: String) -> [PlaceCandidate] {
        candidates.map { c in
            var c = c
            let near = exp(-max(0, c.distance) / 90)
            let text = textMatch(name: c.name, lines: lines)
            let kind = categoryFit(category: c.category, label: dishLabel)
            c.textHit = text
            c.score = min(1, 0.45 * near + 0.35 * text + 0.12 * (c.visited ? 1 : 0) + 0.08 * kind)
            return c
        }
        .sorted { $0.score > $1.score }
    }

    /// 料理の見た目とお店の種類が合うか（カフェで撮ったケーキ、など）
    static func categoryFit(category: String, label: String) -> Double {
        let sweet = ["dessert", "cake", "coffee", "tea", "pastry", "ice_cream", "cookie", "donut", "bread", "baked_goods"]
        switch category {
        case "MKPOICategoryCafe", "MKPOICategoryBakery":
            return sweet.contains(label) ? 1 : 0.3
        case "MKPOICategoryRestaurant", "MKPOICategoryFoodMarket":
            return sweet.contains(label) ? 0.5 : 1
        case "MKPOICategoryNightlife", "MKPOICategoryBrewery", "MKPOICategoryWinery":
            return ["beer", "wine", "cocktail", "alcohol", "drink"].contains(label) ? 1 : 0.4
        default:
            return 0.5
        }
    }

    /// AI を使わないときの決め方。1位が2位より十分高いときだけ自信を高くする
    static func decideOnDevice(_ ranked: [PlaceCandidate]) -> (pick: PlaceCandidate?, confidence: Double) {
        guard let top = ranked.first else { return (nil, 0) }
        let second = ranked.dropFirst().first?.score ?? 0
        let margin = top.score - second
        let confidence = min(1, top.score * 0.7 + margin * 1.2)
        return (top, confidence)
    }

    /// AI の答えと端末の点数を合わせて決める
    static func decide(ranked: [PlaceCandidate], aiIndex: Int?, aiConfidence: Double?) -> (pick: PlaceCandidate?, confidence: Double) {
        guard let aiIndex else { return decideOnDevice(ranked) }
        guard aiIndex >= 0, aiIndex < ranked.count else {
            // AI が「どれでもない」と言った
            return (nil, aiConfidence ?? 0)
        }
        let pick = ranked[aiIndex]
        // AI の自信に、文字が合っていればさらに上乗せ
        let base = aiConfidence ?? 0.5
        let bonus = pick.score > 0.6 ? 0.1 : 0
        return (pick, min(1, base + bonus))
    }

    // MARK: - 端末だけで分かる料理の名前

    /// Vision のラベル → 日本語の料理名とジャンル
    static let dishNames: [String: (dish: String, genre: String)] = [
        "ramen": ("ラーメン", "ラーメン"), "noodles": ("麺料理", "その他"), "sushi": ("寿司", "寿司"),
        "sashimi": ("刺身", "和食"), "pizza": ("ピザ", "イタリアン"), "pasta": ("パスタ", "イタリアン"),
        "spaghetti": ("パスタ", "イタリアン"), "burger": ("ハンバーガー", "ハンバーガー"),
        "hamburger": ("ハンバーガー", "ハンバーガー"), "sandwich": ("サンドイッチ", "カフェ"),
        "curry": ("カレー", "カレー"), "steak": ("ステーキ", "洋食"), "salad": ("サラダ", "その他"),
        "soup": ("スープ", "その他"), "dumpling": ("餃子", "中華"), "fried_chicken": ("唐揚げ", "その他"),
        "cake": ("ケーキ", "スイーツ"), "dessert": ("デザート", "スイーツ"), "ice_cream": ("アイス", "スイーツ"),
        "donut": ("ドーナツ", "スイーツ"), "pastry": ("焼き菓子", "スイーツ"), "cookie": ("クッキー", "スイーツ"),
        "bread": ("パン", "パン"), "baked_goods": ("パン", "パン"), "coffee": ("コーヒー", "カフェ"),
        "tea": ("お茶", "カフェ"), "beer": ("ビール", "居酒屋"), "wine": ("ワイン", "バー"),
        "cocktail": ("カクテル", "バー"), "rice": ("ごはん", "和食"), "meat": ("お肉", "その他"),
        "seafood": ("海鮮", "和食"), "egg": ("卵料理", "その他"), "fries": ("ポテト", "ファストフード"),
        "taco": ("タコス", "エスニック"), "burrito": ("ブリトー", "エスニック"), "hotdog": ("ホットドッグ", "ファストフード"),
        "pancake": ("パンケーキ", "カフェ"), "waffle": ("ワッフル", "カフェ"), "chocolate": ("チョコレート", "スイーツ"),
    ]
}
