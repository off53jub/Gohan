import Foundation
import Security

/// Claude の鍵は端末のキーチェーンにだけ置く（コードにもリポジトリにも書かない）
enum KeyStore {
    private static let service = "com.off53jub.gohan.claude"

    static var claudeKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty, let data = newValue.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Claude に使った額（月ごと。端末の中で数える）
enum Spend {
    private static var monthKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "spend." + f.string(from: Date())
    }

    static var thisMonth: Double { UserDefaults.standard.double(forKey: monthKey) }

    /// 月の上限（ドル）。初めは $10
    static var cap: Double {
        get { UserDefaults.standard.object(forKey: "spend.cap") as? Double ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "spend.cap") }
    }

    static var canSpend: Bool { thisMonth < cap }

    static func add(_ usd: Double) {
        UserDefaults.standard.set(thisMonth + usd, forKey: monthKey)
    }
}

/// Claude の答え（1回の食事について）
struct MealVerdict: Codable, Equatable {
    var is_meal: Bool
    var eaten_out: Bool
    /// 候補の番号。どれでもない・分からないときは -1
    var place_index: Int
    var place_confidence: Double
    var genre: String
    var dishes: [String]
    var summary: String
}

enum ClaudeError: LocalizedError {
    case noKey, capped, refused, unreadable
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: "Claude の鍵がありません"
        case .capped: "今月の Claude の上限に届きました"
        case .refused: "Claude に断られました"
        case .unreadable: "Claude の答えを読めませんでした"
        case .http(let code, let message): "Claude に頼めませんでした（\(code)）: \(message)"
        }
    }
}

/// 写真と候補を Claude に見せて、お店と料理を決めてもらう（Swift には公式の SDK が無いので HTTP で直接呼ぶ）
enum ClaudeVision {
    static let model = "claude-opus-5-5"
    /// 1M トークンあたりの値段（ドル）。入力 $4・出力 $20
    static let inputPrice = 4.0, outputPrice = 20.0

    static var isReady: Bool { KeyStore.claudeKey != nil }

    static let system = """
    あなたは、ある人の食事の写真を記録する係です。思い出と「また行きたいお店」を残すためのアルバムに使います。
    渡す写真は、同じ人が1回の食事のあいだに撮ったものです（料理の写真と、その前後に撮った看板・メニュー・レシートなど）。

    やること:
    1. 写真が食事・飲み物か決める。ペット・人・風景だけなら is_meal を false にする。
    2. お店で食べたか決める。家の食卓・手料理・コンビニの持ち帰りらしければ eaten_out を false にする。
    3. お店の候補の一覧から、写真・写真の中の文字・距離・料理の種類に一番合うお店を番号（place_index）で選ぶ。
       看板やレシートに店名が読めれば、それを一番の手がかりにする。距離が近いだけで料理の種類が合わないお店は選ばない。
       どれも合わない・決め手が無いときは -1 にする。当てずっぽうで選ばない。
       place_confidence は 0〜1。店名が写真で読めた・料理とお店の種類がはっきり合う、なら高く。迷うなら 0.5 未満。
    4. 料理の名前を日本語で、写っている料理ごとに1つずつ（例: 味玉醤油ラーメン、マルゲリータ、抹茶ラテ）。
       メニューに名前が読めればその名前を使う。分からなければ「醤油ラーメン」くらいの一般的な名前にする。
    5. genre は一覧から1つ。summary は「濃厚な豚骨ラーメンと餃子」のような20字くらいの一言。
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "is_meal": ["type": "boolean"],
            "eaten_out": ["type": "boolean"],
            "place_index": ["type": "integer"],
            "place_confidence": ["type": "number"],
            "genre": ["type": "string", "enum": Genre.all],
            "dishes": ["type": "array", "items": ["type": "string"]],
            "summary": ["type": "string"],
        ],
        "required": ["is_meal", "eaten_out", "place_index", "place_confidence", "genre", "dishes", "summary"],
        "additionalProperties": false,
    ]

    /// 写真の説明と候補の一覧（AI に渡す文）
    static func prompt(date: Date, area: String, candidates: [PlaceCandidate], lines: [String], foodCount: Int, clueCount: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E) H:mm"
        var text = "撮った日時: \(f.string(from: date))\n"
        if !area.isEmpty { text += "だいたいの場所: \(area)\n" }
        text += "写真: はじめの \(foodCount) 枚は料理、そのあとの \(clueCount) 枚は前後に撮った看板・メニューなど（無いこともある）\n\n"
        if candidates.isEmpty {
            text += "お店の候補: なし（写真の位置が分からないか、近くにお店が見つからなかった）。place_index は -1 にする。\n"
        } else {
            text += "お店の候補（写真の位置からの距離つき）:\n"
            for (i, c) in candidates.enumerated() {
                let kind = Genre.from(category: c.category).map { "・\($0)" } ?? ""
                let visited = c.visited ? "・前にも行ったお店" : ""
                text += "\(i). \(c.name)（\(Int(c.distance.rounded()))m\(kind)\(visited)）\(c.address)\n"
            }
        }
        if !lines.isEmpty {
            text += "\n写真から読めた文字（読み違いを含む）:\n" + lines.prefix(40).joined(separator: "\n") + "\n"
        }
        return text
    }

    static func judge(food: [Data], clues: [Data], prompt: String) async throws -> MealVerdict {
        guard let key = KeyStore.claudeKey else { throw ClaudeError.noKey }
        guard Spend.canSpend else { throw ClaudeError.capped }
        var content: [[String: Any]] = []
        for data in food + clues {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            // 安全のための断りがあったときは、別のモデルで続けてもらう
            "fallbacks": "default",
        ]
        do {
            return try await send(body, key: key, beta: "server-side-fallback-2026-07-01")
        } catch ClaudeError.http(let code, _) where code == 400 {
            // 予備のモデルの指定が受け付けられないときは、それを外して1回だけやり直す
            body.removeValue(forKey: "fallbacks")
            return try await send(body, key: key, beta: nil)
        }
    }

    private static func send(_ body: [String: Any], key: String, beta: String?) async throws -> MealVerdict {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw ClaudeError.http(status, message)
        }
        let (verdict, usd) = try parse(data)
        Spend.add(usd)
        return verdict
    }

    /// 答えから、決めたことと使った額を取り出す
    static func parse(_ data: Data) throws -> (MealVerdict, Double) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClaudeError.unreadable }
        var usd = 0.0
        if let usage = json["usage"] as? [String: Any] {
            func n(_ k: String) -> Double { (usage[k] as? NSNumber)?.doubleValue ?? 0 }
            let input = n("input_tokens") + n("cache_creation_input_tokens") * 1.25 + n("cache_read_input_tokens") * 0.1
            usd = input * inputPrice / 1_000_000 + n("output_tokens") * outputPrice / 1_000_000
        }
        if (json["stop_reason"] as? String) == "refusal" { throw ClaudeError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              let textData = text.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(MealVerdict.self, from: textData) else {
            throw ClaudeError.unreadable
        }
        return (verdict, usd)
    }
}
