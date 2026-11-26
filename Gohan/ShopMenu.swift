import Foundation

// お店が決まったら、名物をネットで調べて、料理名をお店での呼び名に合わせる（2026-11-26 案10）。
// 「醤油ラーメン」→「特製中華そば」のように。はじめて来たお店のときだけ調べ、調べた料理名はお店に覚えておく。
// 2 回目からは、覚えた料理名を AI に渡すだけなので、調べ直さない。
// 1 軒あたりの費用はまだ測っていない（検索 1〜2 回と、その結果を読む分。数円の見込み＝仮）。月の上限つき。
enum ShopMenu {
    /// 1 か月に調べるお店の数
    static let monthlyCap = 40
    /// 見つからなかったお店を、もう一度調べるまでの日数
    static let retryDays = 90.0

    struct Answer: Equatable {
        /// そのお店の料理の名前（お店での書き方のまま）
        var menu: [String]
        /// この食事の料理名（渡した順・同じ数）
        var dishes: [String]
    }

    static let system = """
    あなたは、食事の記録の料理名を、お店での呼び名にそろえる係です。ウェブ検索で、そのお店のメニュー（看板メニュー・定番）を調べます。
    渡すのは、お店の名前と場所、写真から付けた仮の料理名、料理の写真 1 枚です。
    1. menu に、そのお店の料理の名前を、お店での書き方のまま 12 個まで入れます（値段・説明は入れない）。見つからなければ空にします。
    2. dishes に、渡した仮の料理名を、同じ順番・同じ数で入れます。写真の料理が menu のどれかだとはっきり分かるものだけ、その名前に置きかえます。
       分からないもの・menu に無いものは、渡された名前のまま返します。トッピングや量（特製・味玉・大盛りなど）は、写真で分かるときだけ付けます。
    同じ名前の別のお店と取り違えないよう、場所（街・住所）が合うお店だけを見ます。確かでなければ、menu を空にして、dishes は渡された名前のまま返します。
    答えは最後に、次の形の JSON だけを書きます（前後に説明を書かない）:
    {"menu": ["料理名", "料理名"], "dishes": ["料理名"]}
    """

    static var canUse: Bool {
        AISettings.shopMenu && ClaudeLink.isReady && Spend.canSpend && Net.shared.online && Metrics.value("shopMenus") < monthlyCap
    }

    /// まだ調べていない・前に見つからなくて日がたった
    static func due(_ checkedAt: Date?, now: Date = Date()) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) > retryDays * 86_400
    }

    static func lookup(shop: String, address: String, area: String, genre: String, dishes: [String], photo: Data?) async throws -> Answer? {
        guard canUse else { return nil }
        var text = "お店: \(shop)\n"
        if !address.isEmpty { text += "住所: \(address)\n" }
        if !area.isEmpty { text += "街: \(area)\n" }
        text += "ジャンル: \(genre)\nこの食事の料理（写真から付けた仮の名前）: \(dishes.joined(separator: "、"))\n"
        var content: [[String: Any]] = []
        if let photo {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": photo.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])
        var body: [String: Any] = [
            "model": AIModel.main,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 2,
                       "user_location": ["type": "approximate", "country": "JP"]]],
            "output_config": ["effort": "low"],
            "fallbacks": "default",
        ]
        Metrics.count("shopMenus")
        var data: Data
        do {
            data = try await ClaudeLink.send(ClaudeLink.request("/v1/messages", body: JSONSerialization.data(withJSONObject: body),
                                                                beta: "server-side-fallback-2026-07-01"))
        } catch ClaudeError.http(let code, _) where code == 400 {
            body.removeValue(forKey: "fallbacks")
            data = try await ClaudeLink.send(ClaudeLink.request("/v1/messages", body: JSONSerialization.data(withJSONObject: body)))
        }
        let (answer, usd) = parse(data)
        Spend.add(usd)
        return answer
    }

    /// 答え（文の最後の JSON）と、使った額（検索 1 回 $0.01 を足す）
    static func parse(_ data: Data) -> (Answer?, Double) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, 0) }
        var usd = 0.0
        if let usage = json["usage"] as? [String: Any] {
            func n(_ k: String) -> Double { (usage[k] as? NSNumber)?.doubleValue ?? 0 }
            let price = AIModel.price((json["model"] as? String) ?? AIModel.main)
            let input = n("input_tokens") + n("cache_creation_input_tokens") * 1.25 + n("cache_read_input_tokens") * 0.1
            usd = input * price.input / 1_000_000 + n("output_tokens") * price.output / 1_000_000
            let searches = ((usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? NSNumber)?.doubleValue ?? 0
            usd += searches * 0.01
        }
        guard (json["stop_reason"] as? String) != "refusal" else { return (nil, usd) }
        let text = ((json["content"] as? [[String: Any]]) ?? [])
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let start = text.range(of: "{", options: .backwards), let end = text.range(of: "}", options: .backwards),
              start.lowerBound < end.upperBound,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text[start.lowerBound..<end.upperBound].utf8))) as? [String: Any] else {
            return (nil, usd)
        }
        let menu = clean(obj["menu"] as? [String] ?? [], limit: 12)
        let dishes = (obj["dishes"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (Answer(menu: menu, dishes: dishes), usd)
    }

    /// 空・長すぎ・同じ名前を外す
    static func clean(_ names: [String], limit: Int) -> [String] {
        var out: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 30, !out.contains(name) else { continue }
            out.append(name)
            if out.count >= limit { break }
        }
        return out
    }

    /// 料理名を置きかえてよいか（数が同じで、どれも空でなく長すぎない）。置きかえるものが無ければ nil
    static func renamed(old: [String], new: [String]) -> [String]? {
        guard !old.isEmpty, new.count == old.count, new.allSatisfy({ !$0.isEmpty && $0.count <= 30 }), new != old else { return nil }
        return new
    }

    /// 候補のお店にそえる一言（前に調べた料理名）
    static func note(_ names: [String]) -> String {
        names.isEmpty ? "" : "料理: " + names.prefix(6).joined(separator: "、")
    }
}
