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
        PlaceCandidate(name: name, address: address, category: category, latitude: latitude, longitude: longitude,
                       distance: 0, visited: true, phone: phone, url: url)
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

    /// 一覧の見出し
    var title: String {
        if let place { return place.name }
        if spot == "home" { return "おうちごはん" }
        if spot == "work" { return "職場で" }
        if !eatenOut { return area.isEmpty ? "おうち・持ち帰り" : "おうち・持ち帰り（\(area)）" }
        return area.isEmpty ? "お店が分かりません" : "\(area)のどこか"
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

    /// MapKit のお店の種類から（分からなければ nil）
    static func from(category: String) -> String? {
        switch category {
        case "MKPOICategoryCafe": return "カフェ"
        case "MKPOICategoryBakery": return "パン"
        case "MKPOICategoryBrewery", "MKPOICategoryWinery", "MKPOICategoryNightlife": return "バー"
        default: return nil
        }
    }
}
