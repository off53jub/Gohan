import Foundation

/// 料理の写真で画像検索する（Google Cloud Vision の Web 検出。2026-11-25 実験）。
/// ネット上で似た写真がのっているページ（食べログ・Instagram など）の題名から、候補のお店を探す。
/// 迷ったときだけ・月の上限まで。Google の鍵で Cloud Vision API を使えるようにしておく必要がある（本人の手順）
enum ImageSearch {
    /// 月に 1,000 枚までは無料なので、その内側に収める
    static let monthlyCap = 200

    struct Result: Equatable {
        /// 似た写真がのっているページの題名
        var titles: [String] = []
        /// Google が写真から思いついた言葉（料理名・お店の名前など）
        var entities: [String] = []

        var isEmpty: Bool { titles.isEmpty && entities.isEmpty }
    }

    static var canUse: Bool {
        AISettings.imageSearch && KeyStore.googleKey != nil && Metrics.value("imageSearches") < monthlyCap
    }

    /// いちばん最近の失敗（作る人のメニューで見る）
    static var lastProblem: String? { UserDefaults.standard.string(forKey: "imageSearchLastProblem") }

    static func search(_ jpeg: Data) async -> Result? {
        guard let key = KeyStore.googleKey,
              let url = URL(string: "https://vision.googleapis.com/v1/images:annotate?key=\(key)") else { return nil }
        let body: [String: Any] = ["requests": [[
            "image": ["content": jpeg.base64EncodedString()],
            "features": [["type": "WEB_DETECTION", "maxResults": 10]],
        ]]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Bundle.main.bundleIdentifier ?? "com.off53jub.gohan", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Metrics.count("imageSearches")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            note("つながりませんでした")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            note("HTTP \(status) \(message.prefix(120))")
            return nil
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> Result? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let first = (json["responses"] as? [[String: Any]])?.first else { return nil }
        if let error = first["error"] as? [String: Any] {
            note("\(error["message"] as? String ?? "エラー")")
            return nil
        }
        guard let web = first["webDetection"] as? [String: Any] else { return Result() }
        var result = Result()
        let pages = (web["pagesWithMatchingImages"] as? [[String: Any]]) ?? []
        result.titles = pages.compactMap { page in
            (page["pageTitle"] as? String).map(stripTags)
        }
        .filter { !$0.isEmpty }
        let entities = (web["webEntities"] as? [[String: Any]]) ?? []
        let guesses = (web["bestGuessLabels"] as? [[String: Any]]) ?? []
        result.entities = (entities.compactMap { $0["description"] as? String } + guesses.compactMap { $0["label"] as? String })
            .filter { !$0.isEmpty }
        return result
    }

    /// 候補のお店のうち、ページの題名・言葉に名前が出てきたもの（候補の順＝点数の高い順に見る）
    static func match(_ result: Result, candidates: [PlaceCandidate]) -> PlaceCandidate? {
        let texts = (result.titles + result.entities).map(Matcher.normalize)
        guard !texts.isEmpty else { return nil }
        return candidates.first { c in
            let core = Matcher.normalize(Matcher.coreName(c.name))
            guard core.count >= 2 else { return false }
            return texts.contains { $0.contains(core) }
        }
    }

    /// 題名の <b> などを外す（Google は一致した言葉を太字にして返す）
    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func note(_ problem: String) {
        let stamp = Date().formatted(.dateTime.month().day().hour().minute())
        UserDefaults.standard.set("\(stamp) \(problem)", forKey: "imageSearchLastProblem")
    }
}
