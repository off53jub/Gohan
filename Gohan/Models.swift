import Foundation
import SwiftData

/// 行ったお店（と、まだ行っていない「行ってみたい」お店）
@Model
final class Place {
    /// 同じお店を見分ける印（名前と、だいたいの位置）
    @Attribute(.unique) var key: String
    var name: String
    var address: String
    /// MapKit のお店の種類（MKPOICategoryRestaurant など。分からなければ空）
    var category: String
    var latitude: Double
    var longitude: Double
    var wantAgain: Bool
    var note: String
    var firstVisit: Date
    @Relationship(deleteRule: .nullify, inverse: \Meal.place) var meals: [Meal] = []
    // 2026-11-23 に足したもの（古い記録は初めの値で読む）
    var phone: String = ""
    var url: String = ""
    /// つぎに食べたいもの
    var nextWish: String = ""
    /// 行く前に保存した「行ってみたい」お店
    var wantToTry: Bool = false
    /// どこから保存したか（インスタ・マップ・食べログ・名前で など）
    var savedFrom: String = ""
    /// マップで見つからなくなった（閉店したかも）
    var maybeClosed: Bool = false
    var closedCheckedAt: Date?
    /// 近くに来たと知らせた日（同じ日に何度も知らせない）
    var notifiedAt: Date?
    /// Google の place ID（Google の規約で、ずっと残してよいのはこれだけ。2026-11-26）
    var googleID: String = ""
    /// Google から名前・位置を取ってきた日（Google のお店は、Apple などで見つけ直せなければ 30 日以内に取り直す）
    var googleFetchedAt: Date?
    /// ネットで調べた、このお店の料理の名前（看板メニュー。はじめて来たときに 1 回だけ調べる。2026-11-26 案10）
    var menuNames: [String] = []
    var menuCheckedAt: Date?

    /// Google から取ってきたお店（見つけ直して置きかえる対象）
    var fromGoogle: Bool { category.hasPrefix("google:") }

    init(candidate: PlaceCandidate, date: Date) {
        key = candidate.key
        name = candidate.name
        address = candidate.address
        category = candidate.category
        latitude = candidate.latitude
        longitude = candidate.longitude
        wantAgain = false
        note = ""
        firstVisit = date
        phone = candidate.phone
        url = candidate.url
        googleID = candidate.googleID
    }

    /// 消していない食事（新しい順）
    var visibleMeals: [Meal] { meals.filter { !$0.hidden }.sorted { $0.date > $1.date } }

    /// まだ一度も食べた記録がない（行ってみたいだけのお店）
    var notYet: Bool { visibleMeals.isEmpty }

    /// いちばん多いジャンル
    var mainGenre: String {
        var count: [String: Int] = [:]
        for meal in visibleMeals { count[meal.genre, default: 0] += 1 }
        return count.max { $0.value < $1.value }?.key ?? (Genre.from(category: category) ?? "")
    }

    /// 前に来た日
    var lastVisit: Date? { visibleMeals.first?.date }

    var candidate: PlaceCandidate {
        var c = PlaceCandidate(name: name, address: address, category: category, latitude: latitude, longitude: longitude,
                               distance: 0, visited: true, phone: phone, url: url)
        c.googleID = googleID
        return c
    }
}

/// 1回の食事（同じ場所・同じ時間帯に撮った写真のまとまり）
@Model
final class Meal {
    var id: UUID
    var date: Date
    var endDate: Date
    /// 写真アプリの写真の ID（写真そのものはこのアプリにコピーしない）
    var photoIDs: [String]
    var latitude: Double?
    var longitude: Double?
    /// 近くの地名（お店が分からないときの見出しにも使う）
    var area: String
    var genre: String
    var dishes: [String]
    var summary: String
    /// 0〜1。お店の当たりの自信
    var confidence: Double
    /// 自信が低いので、気が向いたら見てほしい（直さなくても困らない）
    var needsCheck: Bool
    /// 外食か（家・持ち帰りなどは false）
    var eatenOut: Bool
    /// 「食事じゃなかった」と消したもの（設定から戻せる）
    var hidden: Bool
    var note: String
    /// 選び直し用のお店の候補（[PlaceCandidate] の JSON）
    var candidatesData: Data
    /// どうやって決めたか（"claude"・"claude-light"・"batch"・"device"・"known"）
    var source: String
    var createdAt: Date
    var place: Place?
    // 2026-11-23 に足したもの
    /// 前後に撮った看板・メニュー・レシートの写真
    var cluePhotoIDs: [String] = []
    /// "meal"・"cafe"・"snack"・"drink"
    var kind: String = "meal"
    /// そのお店に決めた理由（1行）
    var reason: String = ""
    /// 都道府県（旅行のまとまりに使う）
    var region: String = ""
    /// "home"（おうち）・"work"（職場）・""
    var spot: String = ""
    /// AI の判定を待っている（圏外だった・まとめ処理の順番待ち）
    var aiPending: Bool = false
    /// 記念日のごはん
    var special: Bool = false
    /// 端末が見た料理のラベル（Vision の英語の名前）
    var visionLabel: String = ""
    /// 本人がジャンルを直した（PC から入れ直しても上書きしない。2026-11-25）
    var genreByHand: Bool = false
    /// 写真の iCloud での ID（機種変更のあとに写真を見つけ直すため）
    var cloudIDs: [String] = []
    /// まとめ処理の番号
    var batchID: String = ""
    /// ふたり帖: 相手からの反応（"❤︎" や ひとこと）
    var reactions: [String] = []

    init(date: Date, endDate: Date, photoIDs: [String], latitude: Double?, longitude: Double?) {
        id = UUID()
        self.date = date
        self.endDate = endDate
        self.photoIDs = photoIDs
        self.latitude = latitude
        self.longitude = longitude
        area = ""
        genre = "その他"
        dishes = []
        summary = ""
        confidence = 0
        needsCheck = true
        eatenOut = true
        hidden = false
        note = ""
        candidatesData = Data()
        source = "device"
        createdAt = Date()
    }

    var candidates: [PlaceCandidate] {
        get { (try? JSONDecoder().decode([PlaceCandidate].self, from: candidatesData)) ?? [] }
        set { candidatesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// お店も街も分からない外食の見出し（大7）
    static func quietTitle(dishes: [String], genre: String) -> String {
        if let dish = dishes.first(where: { !$0.isEmpty }) { return dish }
        if !genre.isEmpty, genre != "その他" { return genre }
        return "外で食べたごはん"
    }

    /// 一覧の見出し
    var title: String {
        if let place { return place.name }
        if spot == "home" { return "おうちごはん" }
        if spot == "work" { return "職場で" }
        if !eatenOut { return area.isEmpty ? "おうち・持ち帰り" : "おうち・持ち帰り（\(area)）" }
        if !area.isEmpty { return "\(area)のどこか" }
        // お店も街も分からないときは「分かりません」と書かず、食べたものを見出しにする（大7。2026-11-28）
        return Meal.quietTitle(dishes: dishes, genre: genre)
    }

    var dishText: String { dishes.isEmpty ? genre : dishes.joined(separator: "、") }

    /// このお店の何回目か（1 から。お店が無ければ 0）
    var visitNumber: Int {
        guard let place else { return 0 }
        let older = place.visibleMeals.filter { $0.date < date }.count
        return older + 1
    }

    /// 「はじめて」「1年ぶり」などの印
    var visitMark: String? {
        guard let place else { return nil }
        let visits = place.visibleMeals
        let older = visits.filter { $0.date < date }
        if older.isEmpty { return visits.count > 1 ? "はじめて" : nil }
        if let previous = older.first, date.timeIntervalSince(previous.date) >= 365 * 86_400 {
            let years = Int(date.timeIntervalSince(previous.date) / (365 * 86_400))
            return "\(years)年ぶり"
        }
        return nil
    }

    var kindLabel: String? {
        switch kind {
        case "cafe": "カフェ"
        case "snack": "おやつ"
        case "drink": "飲み物"
        default: nil
        }
    }
}

/// お店の候補（地図の検索・前に行ったお店から）
struct PlaceCandidate: Codable, Hashable, Identifiable {
    var name: String
    var address: String
    var category: String
    var latitude: Double
    var longitude: Double
    /// 写真の位置からの距離（m）
    var distance: Double
    /// この端末での点数（0〜1）
    var score: Double = 0
    /// 前に行ったお店か
    var visited: Bool = false
    var phone: String = ""
    var url: String = ""
    /// 写真の文字と店名の合い方（0〜1。理由の1行に使う）
    var textHit: Double = 0
    /// 営業時間（ホットペッパーの文、または Google の短い形「G|…」）と定休日（精度2）
    var hours: String = ""
    var closedDays: String = ""
    /// お店の紹介写真（ホットペッパーの画像の URL、または Google の写真の名前「places/…」。精度4）
    var photo: String = ""
    /// 2 枚目からの紹介写真（Google の写真の名前。料理の写真を選んで見比べるため。2026-11-25）
    var morePhotos: [String] = []
    /// Google の place ID（Google から取った候補だけ）
    var googleID: String = ""
    /// 写真を撮った時刻に閉まっていたはず（その場で付ける印）
    var closedThen: Bool = false
    // ここから下は、その場かぎりの手がかり（保存しない。2026-11-26）
    /// どんなお店か の一言（ホットペッパーの紹介文・OpenStreetMap の料理の種類・前に調べた料理名。案6）
    var note: String = ""
    /// 前にここで撮った写真と、今回の写真が似ている（端末の中で比べた。案1）
    var alike: Bool = false
    /// 看板などの写真を撮ったとき、カメラが向いていた先にある（案9）
    var facing: Bool = false

    /// 保存する項目（note・alike・facing は入れない。ホットペッパーの紹介文は、決まりで長く置けないため）
    enum CodingKeys: String, CodingKey {
        case name, address, category, latitude, longitude, distance, score, visited, phone, url, textHit
        case hours, closedDays, photo, morePhotos, googleID, closedThen
    }

    var id: String { key }
    var key: String { Self.key(name: name, latitude: latitude, longitude: longitude) }

    init(name: String, address: String, category: String, latitude: Double, longitude: Double, distance: Double,
         score: Double = 0, visited: Bool = false, phone: String = "", url: String = "") {
        self.name = name
        self.address = address
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.distance = distance
        self.score = score
        self.visited = visited
        self.phone = phone
        self.url = url
    }

    // 前の版で保存した候補（phone・url・textHit が無い）も読めるように
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? 0
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        visited = try c.decodeIfPresent(Bool.self, forKey: .visited) ?? false
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        textHit = try c.decodeIfPresent(Double.self, forKey: .textHit) ?? 0
        hours = try c.decodeIfPresent(String.self, forKey: .hours) ?? ""
        closedDays = try c.decodeIfPresent(String.self, forKey: .closedDays) ?? ""
        photo = try c.decodeIfPresent(String.self, forKey: .photo) ?? ""
        morePhotos = try c.decodeIfPresent([String].self, forKey: .morePhotos) ?? []
        googleID = try c.decodeIfPresent(String.self, forKey: .googleID) ?? ""
        closedThen = try c.decodeIfPresent(Bool.self, forKey: .closedThen) ?? false
    }

    static func key(name: String, latitude: Double, longitude: Double) -> String {
        "\(Matcher.normalize(name))|\(String(format: "%.3f", latitude))|\(String(format: "%.3f", longitude))"
    }
}

/// ジャンル（AI にもこの中から選ばせる）
enum Genre {
    static let all = [
        "ラーメン", "つけ麺", "そば・うどん", "寿司", "和食", "定食", "丼", "焼肉", "焼き鳥", "居酒屋",
        "中華", "韓国料理", "カレー", "エスニック", "イタリアン", "フレンチ", "洋食", "ハンバーガー",
        "ファストフード", "カフェ", "スイーツ", "パン", "バー", "鍋", "お好み焼き", "その他",
    ]

    /// お店の種類から（MapKit・Google・ホットペッパー。分からなければ nil）
    static func from(category: String) -> String? {
        if category.hasPrefix("genre:") { return hotpepper[String(category.dropFirst(6))] }
        if category.hasPrefix("google:") { return google[String(category.dropFirst(7))] }
        // Yahoo!（日本語のジャンル名）・Foursquare（英語の種類名）・OpenStreetMap（cuisine）。2026-11-26
        if category.hasPrefix("yahoo:") { return Matcher.genre(fromText: String(category.dropFirst(6))) }
        if category.hasPrefix("fsq:") { return fromEnglish(String(category.dropFirst(4))) }
        if category.hasPrefix("osm:") { return fromEnglish(String(category.dropFirst(4)).replacingOccurrences(of: "_", with: " ")) }
        switch category {
        case "MKPOICategoryCafe": return "カフェ"
        case "MKPOICategoryBakery": return "パン"
        case "MKPOICategoryBrewery", "MKPOICategoryWinery", "MKPOICategoryNightlife": return "バー"
        default: return nil
        }
    }

    /// 英語の料理・お店の種類（Foursquare の「Ramen Restaurant」・OpenStreetMap の「ramen;japanese」など）
    static func fromEnglish(_ text: String) -> String? {
        let t = text.lowercased()
        let table: [(String, String)] = [
            ("tsukemen", "つけ麺"), ("ramen", "ラーメン"), ("noodle", "ラーメン"), ("soba", "そば・うどん"), ("udon", "そば・うどん"),
            ("sushi", "寿司"), ("yakitori", "焼き鳥"), ("yakiniku", "焼肉"), ("bbq", "焼肉"), ("barbecue", "焼肉"),
            ("okonomiyaki", "お好み焼き"), ("monja", "お好み焼き"), ("takoyaki", "お好み焼き"), ("izakaya", "居酒屋"),
            ("donburi", "丼"), ("gyudon", "丼"), ("beef bowl", "丼"), ("curry", "カレー"), ("indian", "カレー"),
            ("korean", "韓国料理"), ("chinese", "中華"), ("dumpling", "中華"), ("thai", "エスニック"), ("vietnamese", "エスニック"),
            ("italian", "イタリアン"), ("pizza", "イタリアン"), ("pasta", "イタリアン"), ("french", "フレンチ"), ("bistro", "フレンチ"),
            ("burger", "ハンバーガー"), ("fast food", "ファストフード"), ("fried chicken", "ファストフード"),
            ("dessert", "スイーツ"), ("cake", "スイーツ"), ("ice cream", "スイーツ"), ("pastry", "スイーツ"), ("bakery", "パン"),
            // 「steak」「teishoku」に tea が含まれるので、tea より先に見る
            ("hot pot", "鍋"), ("shabu", "鍋"), ("sukiyaki", "鍋"), ("tonkatsu", "定食"), ("teishoku", "定食"),
            ("steak", "洋食"), ("western", "洋食"), ("diner", "洋食"),
            ("coffee", "カフェ"), ("cafe", "カフェ"), ("tea", "カフェ"), ("bar", "バー"), ("pub", "バー"),
            ("japanese", "和食"),
        ]
        return table.first { t.contains($0.0) }?.1
    }

    /// ホットペッパーのジャンル名
    static let hotpepper: [String: String] = [
        "居酒屋": "居酒屋", "ダイニングバー・バル": "バー", "バー・カクテル": "バー", "和食": "和食", "洋食": "洋食",
        "イタリアン・フレンチ": "イタリアン", "中華": "中華", "焼肉・ホルモン": "焼肉", "韓国料理": "韓国料理",
        "アジア・エスニック料理": "エスニック", "各国料理": "エスニック", "ラーメン": "ラーメン",
        "お好み焼き・もんじゃ": "お好み焼き", "カフェ・スイーツ": "カフェ",
    ]

    /// Google のお店の種類
    static let google: [String: String] = [
        "ramen_restaurant": "ラーメン", "sushi_restaurant": "寿司", "japanese_restaurant": "和食", "chinese_restaurant": "中華",
        "korean_restaurant": "韓国料理", "italian_restaurant": "イタリアン", "pizza_restaurant": "イタリアン",
        "french_restaurant": "フレンチ", "hamburger_restaurant": "ハンバーガー", "fast_food_restaurant": "ファストフード",
        "cafe": "カフェ", "coffee_shop": "カフェ", "bakery": "パン", "bar": "バー", "pub": "バー", "wine_bar": "バー",
        "barbecue_restaurant": "焼肉", "indian_restaurant": "エスニック", "thai_restaurant": "エスニック",
        "vietnamese_restaurant": "エスニック", "mexican_restaurant": "エスニック", "dessert_shop": "スイーツ",
        "ice_cream_shop": "スイーツ", "confectionery": "スイーツ", "steak_house": "洋食", "seafood_restaurant": "和食",
    ]
}
