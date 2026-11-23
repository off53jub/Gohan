import Foundation
import Security

/// 鍵は端末のキーチェーンにだけ置く（コードにもリポジトリにも書かない）
enum KeyStore {
    static var claudeKey: String? {
        get { read("com.off53jub.gohan.claude") }
        set { write("com.off53jub.gohan.claude", newValue) }
    }

    /// 中継サーバーの合言葉（便2）
    static var relayToken: String? {
        get { read("com.off53jub.gohan.relay") }
        set { write("com.off53jub.gohan.relay", newValue) }
    }

    private static func read(_ service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private static func write(_ service: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
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

/// モデルと値段（1M トークンあたりのドル）
enum AIModel {
    static let main = "claude-opus-5-5"
    /// かんたんな写真だけに使う（便12。本人が 2026-11-23 に「全部作って」で認めた）
    static let light = "claude-haiku-5-5"

    static func price(_ model: String) -> (input: Double, output: Double) {
        model == light ? (0.10, 0.50) : (4.0, 20.0)
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
    /// "meal"・"cafe"・"snack"・"drink"
    var kind: String = "meal"
    /// お店に決めた理由（1行）
    var reason: String = ""

    init(is_meal: Bool, eaten_out: Bool, place_index: Int, place_confidence: Double, genre: String, dishes: [String],
         summary: String, kind: String = "meal", reason: String = "") {
        self.is_meal = is_meal
        self.eaten_out = eaten_out
        self.place_index = place_index
        self.place_confidence = place_confidence
        self.genre = genre
        self.dishes = dishes
        self.summary = summary
        self.kind = kind
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        is_meal = try c.decode(Bool.self, forKey: .is_meal)
        eaten_out = try c.decode(Bool.self, forKey: .eaten_out)
        place_index = try c.decode(Int.self, forKey: .place_index)
        place_confidence = try c.decode(Double.self, forKey: .place_confidence)
        genre = try c.decode(String.self, forKey: .genre)
        dishes = try c.decode([String].self, forKey: .dishes)
        summary = try c.decode(String.self, forKey: .summary)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "meal"
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

enum ClaudeError: LocalizedError {
    case noKey, capped, refused, unreadable, offline
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: "AI の鍵がありません"
        case .capped: "今月の AI はお休み中です（上限に届きました）"
        case .refused: "AI に断られました"
        case .unreadable: "AI の答えを読めませんでした"
        case .offline: "つながっていないので、あとで AI に見てもらいます"
        case .http(let code, let message): "AI に頼めませんでした（\(code)）: \(message)"
        }
    }
}

/// Claude への道（直接か、中継サーバーを通すか。Swift には公式の SDK が無いので HTTP で直接呼ぶ）
enum ClaudeLink {
    static var usesRelay: Bool { !AISettings.relayURL.isEmpty && KeyStore.relayToken != nil }

    /// 使える状態か（端末だけのモードでは使わない）
    static var isReady: Bool {
        !AISettings.deviceOnly && (KeyStore.claudeKey != nil || usesRelay)
    }

    static func request(_ path: String, method: String = "POST", body: Data? = nil, beta: String? = nil) throws -> URLRequest {
        let base = usesRelay ? AISettings.relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : "https://api.anthropic.com"
        guard let url = URL(string: base + path) else { throw ClaudeError.noKey }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        if usesRelay {
            request.setValue(KeyStore.relayToken, forHTTPHeaderField: "x-gohan-token")
        } else {
            guard let key = KeyStore.claudeKey else { throw ClaudeError.noKey }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = body
        return request
    }

    static func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            if [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed]
                .contains(error.code) {
                throw ClaudeError.offline
            }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            if status == 402 { throw ClaudeError.capped }
            throw ClaudeError.http(status, message)
        }
        return data
    }

    /// 文字だけで答えてもらう（ことばで探す・行ってみたいお店の名前など）。JSON の形を決めて返してもらう
    static func ask(system: String, text: String, schema: [String: Any], effort: String = "low") async throws -> Data {
        guard isReady else { throw ClaudeError.noKey }
        guard Spend.canSpend else { throw ClaudeError.capped }
        var body: [String: Any] = [
            "model": AIModel.main,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": text]],
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        var data: Data
        do {
            data = try await send(request("/v1/messages", body: JSONSerialization.data(withJSONObject: body), beta: "server-side-fallback-2026-07-01"))
        } catch ClaudeError.http(let code, _) where code == 400 {
            body.removeValue(forKey: "fallbacks")
            data = try await send(request("/v1/messages", body: JSONSerialization.data(withJSONObject: body)))
        }
        let (text, usd) = try ClaudeVision.textAndCost(data, model: AIModel.main)
        Spend.add(usd)
        guard let out = text.data(using: .utf8) else { throw ClaudeError.unreadable }
        return out
    }
}

/// 写真と候補を Claude に見せて、お店と料理を決めてもらう
enum ClaudeVision {
    static let model = AIModel.main
    /// 1M トークンあたりの値段（ドル）。入力 $4・出力 $20
    static let inputPrice = 4.0, outputPrice = 20.0

    static var isReady: Bool { ClaudeLink.isReady }

    static let system = """
    あなたは、ある人の食事の写真を記録する係です。思い出と「また行きたいお店」を残すためのアルバムに使います。
    渡す写真は、同じ人が1回の食事のあいだに撮ったものです（料理の写真と、その前後に撮った看板・メニュー・レシートなど）。
    人の顔は隠してあることがあります。

    やること:
    1. 写真が食事・飲み物か決める。ペット・人・風景だけなら is_meal を false にする。
    2. お店で食べたか決める。家の食卓・手料理・コンビニの持ち帰りらしければ eaten_out を false にする。
    3. お店の候補の一覧から、写真・写真の中の文字・距離・料理の種類に一番合うお店を番号（place_index）で選ぶ。
       看板やレシートに店名が読めれば、それを一番の手がかりにする。予定表の予定名や場所も手がかりにしてよい。
       距離が近いだけで料理の種類が合わないお店は選ばない。
       どれも合わない・決め手が無いときは -1 にする。当てずっぽうで選ばない。
       place_confidence は 0〜1。店名が写真で読めた・料理とお店の種類がはっきり合う、なら高く。迷うなら 0.5 未満。
    4. 料理の名前を日本語で、写っている料理ごとに1つずつ（例: 味玉醤油ラーメン、マルゲリータ、抹茶ラテ）。
       メニューに名前が読めればその名前を使う。分からなければ「醤油ラーメン」くらいの一般的な名前にする。
    5. genre は一覧から1つ。summary は「濃厚な豚骨ラーメンと餃子」のような20字くらいの一言。
    6. kind は、しっかりした食事なら meal、カフェでの軽いものなら cafe、おやつ・甘いものだけなら snack、飲み物だけなら drink。
    7. reason は、そのお店に決めた理由を30字くらいで（例: 看板の「こもれび」と場所が合った）。お店を選ばないときは空にする。
    """

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "is_meal": ["type": "boolean"],
                "eaten_out": ["type": "boolean"],
                "place_index": ["type": "integer"],
                "place_confidence": ["type": "number"],
                "genre": ["type": "string", "enum": Genre.all],
                "dishes": ["type": "array", "items": ["type": "string"]],
                "summary": ["type": "string"],
                "kind": ["type": "string", "enum": ["meal", "cafe", "snack", "drink"]],
                "reason": ["type": "string"],
            ],
            "required": ["is_meal", "eaten_out", "place_index", "place_confidence", "genre", "dishes", "summary", "kind", "reason"],
            "additionalProperties": false,
        ]
    }

    /// 写真の説明と候補の一覧（AI に渡す文）
    static func prompt(date: Date, area: String, candidates: [PlaceCandidate], lines: [String], foodCount: Int, clueCount: Int,
                       event: String? = nil, receipt: [String] = [], knownPlace: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E) H:mm"
        var text = "撮った日時: \(f.string(from: date))\n"
        if !area.isEmpty { text += "だいたいの場所: \(area)\n" }
        if let event, !event.isEmpty { text += "その時間の予定表: \(event)\n" }
        text += "写真: はじめの \(foodCount) 枚は料理、そのあとの \(clueCount) 枚は前後に撮った看板・メニューなど（無いこともある）\n\n"
        if let knownPlace {
            text += "お店はもう分かっています（前にも来たお店）: 0. \(knownPlace)\nplace_index は 0 にして、料理を中心に見てください。\n"
        } else if candidates.isEmpty {
            text += "お店の候補: なし（写真の位置が分からないか、近くにお店が見つからなかった）。place_index は -1 にする。\n"
        } else {
            text += "お店の候補（写真の位置からの距離つき）:\n"
            for (i, c) in candidates.enumerated() {
                let kind = Genre.from(category: c.category).map { "・\($0)" } ?? ""
                let visited = c.visited ? "・前にも行ったお店" : ""
                text += "\(i). \(c.name)（\(Int(c.distance.rounded()))m\(kind)\(visited)）\(c.address)\n"
            }
        }
        if !receipt.isEmpty {
            text += "\nレシートの上のほうに書いてあった文字（店名かもしれない）: " + receipt.joined(separator: "、") + "\n"
        }
        if !lines.isEmpty {
            text += "\n写真から読めた文字（読み違いを含む）:\n" + lines.prefix(40).joined(separator: "\n") + "\n"
        }
        return text
    }

    /// 送る中身（すぐ聞くときも、まとめ処理のときも同じ）
    static func body(food: [Data], clues: [Data], prompt: String, light: Bool) -> [String: Any] {
        var content: [[String: Any]] = []
        for data in food + clues {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        return [
            "model": light ? AIModel.light : AIModel.main,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": ["effort": light ? "low" : "medium", "format": ["type": "json_schema", "schema": schema]],
        ]
    }

    static func judge(food: [Data], clues: [Data], prompt: String, light: Bool = false) async throws -> MealVerdict {
        guard ClaudeLink.isReady else { throw ClaudeError.noKey }
        guard Spend.canSpend else { throw ClaudeError.capped }
        var params = Self.body(food: food, clues: clues, prompt: prompt, light: light)
        if light {
            // 軽いモデルには、断られたときの予備のモデルの指定が無い。うまくいかなければ、ふつうのモデルで聞き直す
            do {
                return try await sendJudge(params, beta: nil)
            } catch ClaudeError.http, ClaudeError.unreadable, ClaudeError.refused {
                return try await judge(food: food, clues: clues, prompt: prompt, light: false)
            }
        }
        // 安全のための断りがあったときは、別のモデルで続けてもらう
        params["fallbacks"] = "default"
        do {
            return try await sendJudge(params, beta: "server-side-fallback-2026-07-01")
        } catch ClaudeError.http(let code, _) where code == 400 {
            // 予備のモデルの指定が受け付けられないときは、それを外して1回だけやり直す
            params.removeValue(forKey: "fallbacks")
            return try await sendJudge(params, beta: nil)
        }
    }

    private static func sendJudge(_ body: [String: Any], beta: String?) async throws -> MealVerdict {
        let data = try await ClaudeLink.send(ClaudeLink.request("/v1/messages", body: JSONSerialization.data(withJSONObject: body), beta: beta))
        let (verdict, usd) = try parse(data, model: body["model"] as? String ?? AIModel.main)
        Spend.add(usd)
        return verdict
    }

    /// 答えから、決めたことと使った額を取り出す
    static func parse(_ data: Data, model: String = AIModel.main, discount: Double = 1) throws -> (MealVerdict, Double) {
        let (text, usd) = try textAndCost(data, model: model, discount: discount)
        guard let textData = text.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(MealVerdict.self, from: textData) else {
            throw ClaudeError.unreadable
        }
        return (verdict, usd)
    }

    /// 答えの文と、使った額（まとめ処理は半額なので discount 0.5）
    static func textAndCost(_ data: Data, model: String, discount: Double = 1) throws -> (String, Double) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClaudeError.unreadable }
        var usd = 0.0
        if let usage = json["usage"] as? [String: Any] {
            func n(_ k: String) -> Double { (usage[k] as? NSNumber)?.doubleValue ?? 0 }
            let price = AIModel.price((json["model"] as? String) ?? model)
            let input = n("input_tokens") + n("cache_creation_input_tokens") * 1.25 + n("cache_read_input_tokens") * 0.1
            usd = (input * price.input / 1_000_000 + n("output_tokens") * price.output / 1_000_000) * discount
        }
        if (json["stop_reason"] as? String) == "refusal" { throw ClaudeError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw ClaudeError.unreadable
        }
        return (text, usd)
    }
}

/// 古い写真のまとめ処理（便13。急がない分は半額の窓口で）
enum BatchQueue {
    private static var dir: URL {
        let url = URL.applicationSupportDirectory.appendingPathComponent("batch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 送る前の頼みごと（食事の ID → 送る中身）を置く
    static func enqueue(mealID: UUID, body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        try? data.write(to: dir.appendingPathComponent("\(mealID.uuidString).json"), options: .atomic)
    }

    static var queued: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    /// 送ったまとめ処理の番号
    static var submitted: [String] {
        get { UserDefaults.standard.stringArray(forKey: "batch.submitted") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "batch.submitted") }
    }

    /// 置いてある頼みごとを、まとめて送る（1回に 40 件まで）。送った件数を返す
    static func submit() async throws -> Int {
        let files = Array(queued.prefix(40))
        guard !files.isEmpty, ClaudeLink.isReady, Spend.canSpend else { return 0 }
        var requests: [[String: Any]] = []
        for file in files {
            // 中身は自分で書いたファイル（写真の JPEG を含む）
            guard let data = try? Data(contentsOf: file),
                  let params = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            requests.append(["custom_id": file.deletingPathExtension().lastPathComponent, "params": params])
        }
        let body = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let data = try await ClaudeLink.send(ClaudeLink.request("/v1/messages/batches", body: body))
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = json["id"] as? String else {
            throw ClaudeError.unreadable
        }
        submitted.append(id)
        for file in files { try? FileManager.default.removeItem(at: file) }
        return requests.count
    }

    /// 終わったまとめ処理の答え（食事の ID → 答え）
    static func collect() async -> [(UUID, Result<MealVerdict, Error>)] {
        var out: [(UUID, Result<MealVerdict, Error>)] = []
        var still: [String] = []
        for id in submitted {
            do {
                let data = try await ClaudeLink.send(ClaudeLink.request("/v1/messages/batches/\(id)", method: "GET"))
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (json?["processing_status"] as? String) == "ended" else {
                    still.append(id)
                    continue
                }
                let results = try await ClaudeLink.send(ClaudeLink.request("/v1/messages/batches/\(id)/results", method: "GET"))
                out += parseResults(results)
            } catch {
                // 古すぎて見つからない（29 日で消える）ものは捨て、通信の失敗は次に回す
                if case ClaudeError.http(let code, _) = error, code == 404 { continue }
                still.append(id)
            }
        }
        submitted = still
        return out
    }

    /// 結果の JSONL を読む（並びは送った順とは限らないので、custom_id で引く）
    static func parseResults(_ data: Data) -> [(UUID, Result<MealVerdict, Error>)] {
        var out: [(UUID, Result<MealVerdict, Error>)] = []
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let customID = json["custom_id"] as? String, let mealID = UUID(uuidString: customID),
                  let result = json["result"] as? [String: Any] else { continue }
            if (result["type"] as? String) == "succeeded", let message = result["message"],
               let messageData = try? JSONSerialization.data(withJSONObject: message) {
                do {
                    let (verdict, usd) = try ClaudeVision.parse(messageData, discount: 0.5)
                    Spend.add(usd)
                    out.append((mealID, .success(verdict)))
                } catch {
                    out.append((mealID, .failure(error)))
                }
            } else {
                out.append((mealID, .failure(ClaudeError.unreadable)))
            }
        }
        return out
    }
}
