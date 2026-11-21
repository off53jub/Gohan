import Foundation
import SwiftData

/// 行ったお店。同じお店に何回行ったか・また行きたいかをここに持つ
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
    }

    /// 消していない食事
    var visibleMeals: [Meal] { meals.filter { !$0.hidden }.sorted { $0.date > $1.date } }
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
    /// どうやって決めたか（"claude" か "device"）
    var source: String
    var createdAt: Date
    var place: Place?

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
        if !eatenOut { return area.isEmpty ? "おうち・持ち帰り" : "おうち・持ち帰り（\(area)）" }
        return area.isEmpty ? "お店が分かりません" : "\(area)のどこか"
    }

    var dishText: String { dishes.isEmpty ? genre : dishes.joined(separator: "・") }
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

    var id: String { key }
    var key: String { Self.key(name: name, latitude: latitude, longitude: longitude) }

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

    static func emoji(_ genre: String) -> String {
        switch genre {
        case "ラーメン", "つけ麺": return "🍜"
        case "そば・うどん": return "🥢"
        case "寿司": return "🍣"
        case "和食", "定食": return "🍱"
        case "丼": return "🍚"
        case "焼肉": return "🥩"
        case "焼き鳥", "居酒屋": return "🏮"
        case "中華": return "🥟"
        case "韓国料理": return "🌶️"
        case "カレー", "エスニック": return "🍛"
        case "イタリアン": return "🍝"
        case "フレンチ", "洋食": return "🍽️"
        case "ハンバーガー", "ファストフード": return "🍔"
        case "カフェ": return "☕️"
        case "スイーツ": return "🍰"
        case "パン": return "🥐"
        case "バー": return "🍸"
        case "鍋": return "🍲"
        case "お好み焼き": return "🥞"
        default: return "🍴"
        }
    }
}
