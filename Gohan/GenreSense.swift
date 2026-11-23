import Foundation

// ジャンルの見分け（2026-11-24。本人「ラーメンなのにスープ・パスタになる」）。
// 端末の写真の判定（Vision）は英語の名前を1つ選ぶだけで、日本の麺料理をうまく分けられない。
// そこで、写真の上位の名前・看板やメニューの文字・お店の名前・本人が直したジャンル を合わせて決める。

struct GenreGuess: Equatable {
    var genre: String
    var dish: String?
    /// どこから決めたか（"name"・"text"・"learned"・"photo"）
    var from: String
}

extension Matcher {
    /// ジャンル → 店名・看板・メニューに出やすいことば（上から順に見る。中華そば は そば より先に ラーメン で当たる）
    static let genreWords: [(genre: String, words: [String])] = [
        ("つけ麺", ["つけ麺", "つけめん", "沾麺"]),
        ("ラーメン", ["ラーメン", "らーめん", "らあめん", "らぁめん", "らぁ麺", "拉麺", "中華そば", "中華蕎麦", "支那そば",
                    "麺屋", "麺や", "麺処", "麺家", "麺堂", "家系", "二郎", "豚骨", "とんこつ", "替玉", "替え玉", "煮干", "まぜそば", "油そば", "担々麺"]),
        ("そば・うどん", ["蕎麦", "そば処", "手打ちそば", "うどん", "饂飩", "讃岐", "立ち食いそば", "そば"]),
        ("寿司", ["寿司", "鮨", "すし", "スシ"]),
        ("焼肉", ["焼肉", "焼き肉", "ホルモン", "カルビ", "ジンギスカン"]),
        ("焼き鳥", ["焼鳥", "焼き鳥", "やきとり", "串焼"]),
        ("お好み焼き", ["お好み焼", "もんじゃ", "たこ焼", "鉄板焼"]),
        ("鍋", ["しゃぶしゃぶ", "すき焼", "もつ鍋", "鍋"]),
        ("中華", ["中華料理", "中国料理", "餃子", "飯店", "菜館", "四川", "麻婆", "小籠包", "点心"]),
        ("韓国料理", ["韓国", "サムギョプサル", "スンドゥブ", "ビビンバ", "トッポギ", "チゲ"]),
        ("カレー", ["カレー", "curry"]),
        ("エスニック", ["タイ料理", "ベトナム", "フォー", "ガパオ", "インド料理", "ネパール", "タコス", "メキシカン"]),
        ("イタリアン", ["トラットリア", "リストランテ", "オステリア", "ピッツェリア", "ピッツァ", "ピザ", "パスタ", "trattoria", "pizzeria", "イタリアン"]),
        ("フレンチ", ["ビストロ", "フレンチ", "bistro", "ブラッスリー", "brasserie"]),
        ("ハンバーガー", ["ハンバーガー", "バーガー", "burger"]),
        ("洋食", ["洋食", "グリル", "ハンバーグ", "オムライス", "ステーキ"]),
        ("丼", ["牛丼", "天丼", "かつ丼", "海鮮丼", "丼"]),
        ("定食", ["定食", "食堂"]),
        ("スイーツ", ["パティスリー", "patisserie", "ケーキ", "スイーツ", "甘味", "パフェ", "クレープ", "ジェラート"]),
        ("パン", ["ベーカリー", "ブーランジェリー", "bakery", "boulangerie", "パン屋"]),
        ("カフェ", ["カフェ", "珈琲", "コーヒー", "喫茶", "cafe", "coffee"]),
        ("居酒屋", ["居酒屋", "酒場", "大衆酒", "炉端", "立ち飲み"]),
        ("バー", ["バー", "bar", "pub"]),
    ]

    /// なかまのジャンル（ちがっても「合わない」とは言わない）
    static let genreFamilies: [Set<String>] = [
        ["ラーメン", "つけ麺"], ["カフェ", "スイーツ", "パン"], ["居酒屋", "焼き鳥", "バー"],
        ["和食", "定食", "丼", "寿司", "そば・うどん", "鍋"], ["洋食", "フレンチ", "イタリアン", "ハンバーガー"],
        ["ハンバーガー", "ファストフード"], ["エスニック", "カレー"],
    ]

    /// 文字（店名・看板・メニュー）に出ていることばから、ジャンルを決める（無ければ nil）
    static func genre(fromText text: String) -> String? {
        for (genre, words) in genreWords where words.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return genre
        }
        return nil
    }

    /// 写真の文字の行から（2 回以上出てきたジャンル。メニューの一品だけで決めない）
    static func genre(fromLines lines: [String]) -> String? {
        var count: [String: Int] = [:]
        for line in lines {
            if let g = genre(fromText: line) { count[g, default: 0] += 1 }
        }
        guard let best = count.max(by: { $0.value < $1.value }), best.value >= 2 else { return nil }
        return best.key
    }

    /// 写真の判定（上位の名前と強さ）から。日本の外食なので、麺と汁が見えれば まずラーメン
    static func genre(fromLabels labels: [String: Double]) -> GenreGuess? {
        func has(_ name: String, _ min: Double = 0.1) -> Bool { (labels[name] ?? 0) >= min }
        let noodle = has("ramen") || has("noodles") || has("pho") || has("udon") || has("soba")
        // 汁の中の麺は、パスタと判定されていてもラーメンとみなす（本人の例: ラーメンがパスタになった）
        if has("ramen") || ((noodle || has("pasta") || has("spaghetti")) && has("soup", 0.05)) {
            return GenreGuess(genre: "ラーメン", dish: "ラーメン", from: "photo")
        }
        if (has("pasta") || has("spaghetti")), !has("soup", 0.05) {
            return GenreGuess(genre: "イタリアン", dish: "パスタ", from: "photo")
        }
        if noodle { return GenreGuess(genre: "ラーメン", dish: "麺料理", from: "photo") }
        guard let top = labels.filter({ !PhotoVision.broadLabels.contains($0.key) }).max(by: { $0.value < $1.value }) else { return nil }
        // 汁ものだけ（麺が見えない）は、スープと決めつけない
        if top.key == "soup" { return nil }
        guard let dish = dishNames[top.key] else { return nil }
        return GenreGuess(genre: dish.genre, dish: dish.dish, from: "photo")
    }

    /// まとめて決める: お店の名前 → 写真の文字 → 本人が直したジャンル → 写真の判定
    static func guessGenre(labels: [String: Double], lines: [String], shopName: String?, learned: String?) -> GenreGuess? {
        let photo = genre(fromLabels: labels)
        if let shopName, let g = genre(fromText: shopName) {
            return GenreGuess(genre: g, dish: photo?.genre == g ? photo?.dish : nil, from: "name")
        }
        if let g = genre(fromLines: lines) {
            return GenreGuess(genre: g, dish: photo?.genre == g ? photo?.dish : nil, from: "text")
        }
        if let learned { return GenreGuess(genre: learned, dish: nil, from: "learned") }
        return photo
    }

    /// お店の名前・種類から分かるジャンル
    static func candidateGenre(_ c: PlaceCandidate) -> String? {
        genre(fromText: c.name) ?? Genre.from(category: c.category)
    }

    /// 写真のジャンルとお店のジャンルの合い方（合う +1・分からない 0・合わない -1）
    static func genreFit(photo: String?, candidate: PlaceCandidate) -> Double {
        guard let photo, photo != "その他", let shop = candidateGenre(candidate) else { return 0 }
        if shop == photo { return 1 }
        if genreFamilies.contains(where: { $0.contains(shop) && $0.contains(photo) }) { return 0.5 }
        return -1
    }

    /// ジャンルが合うお店を上へ、はっきり合わないお店を下へ
    static func applyGenre(_ ranked: [PlaceCandidate], photoGenre: String?) -> [PlaceCandidate] {
        guard photoGenre != nil else { return ranked }
        return ranked.map { c in
            var c = c
            let fit = genreFit(photo: photoGenre, candidate: c)
            c.score = min(1, max(0, c.score + (fit > 0 ? 0.12 * fit : 0.08 * fit)))
            return c
        }
        .sorted { $0.score > $1.score }
    }

    /// 写真の上位の名前を、食事の写真ぜんぶで合わせる（いちばん強い値を残す）
    static func mergeLabels(_ photos: [SeenPhoto]) -> [String: Double] {
        var out: [String: Double] = [:]
        for p in photos {
            let labels = p.labels.isEmpty && !p.label.isEmpty ? [p.label: p.food] : p.labels
            for (k, v) in labels { out[k] = max(out[k] ?? 0, v) }
        }
        return out
    }
}

/// 本人が直したジャンルを覚える（写真の判定の名前 → ジャンル。2 回そろったら使う）
enum GenreLearn {
    private static var all: [String: [String: Int]] {
        get { (UserDefaults.standard.dictionary(forKey: "genre.learn") as? [String: [String: Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "genre.learn") }
    }

    static func record(label: String, genre: String) {
        guard !label.isEmpty else { return }
        var copy = all
        copy[label, default: [:]][genre, default: 0] += 1
        all = copy
    }

    static func lookup(_ label: String) -> String? {
        guard let counts = all[label], let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 else { return nil }
        return best.key
    }
}
