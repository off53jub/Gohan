import Foundation
import UIKit

/// 迷ったときだけ、候補のお店の紹介写真（ホットペッパー・Google）と食事の写真を AI に見比べてもらう（精度4。2026-11-24）
enum LookAlike {
    struct Answer: Codable, Equatable {
        var index: Int
        var confidence: Double
        var reason: String
    }

    static let system = """
    あなたは、食事の写真がどのお店で撮られたかを見比べる係です。
    はじめに、ある人が撮った料理の写真を渡します。そのあとに、近くのお店の候補と、それぞれのお店の紹介写真（料理・店内・外観のどれか）を渡します。
    料理の種類・盛り付け・器・トレー・テーブル・店内の雰囲気が、どのお店の写真と一番合うかを選び、番号を index に入れます。
    紹介写真はお店の一部しか写していません。似ていないだけで決めつけず、決め手（同じ器・同じ料理・同じ内装）があるときだけ confidence を高くします。
    はっきり合うお店が無ければ index を -1、confidence を 0 にします。
    reason は決め手を20字くらいで書きます。
    """

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "index": ["type": "integer"],
                "confidence": ["type": "number"],
                "reason": ["type": "string"],
            ],
            "required": ["index", "confidence", "reason"],
            "additionalProperties": false,
        ]
    }

    /// Google の料金を使いすぎないための、月の上限（本人「Google は使いすぎ注意」2026-11-25）
    static let monthlyShopLookups = 150   // 写真の無いお店を Google で調べる回数
    static let monthlyPhotoFetches = 300  // Google から取るお店の写真の枚数

    /// 紹介写真のある候補（点数の高い 8 軒のうち、4 軒まで）
    static func pickable(_ ranked: [PlaceCandidate]) -> [PlaceCandidate] {
        Array(ranked.prefix(8).filter { !$0.photo.isEmpty && !$0.closedThen }.prefix(4))
    }

    /// 見比べる候補をそろえる。紹介写真の無い上位のお店は、Google で名前から探して写真を取ってくる（迷ったときだけ・月の上限まで）
    static func withPhotos(_ ranked: [PlaceCandidate], latitude: Double, longitude: Double) async -> [PlaceCandidate] {
        var out: [PlaceCandidate] = []
        for c in ranked.prefix(8) where !c.closedThen {
            if out.count >= 4 { break }
            if !c.photo.isEmpty { out.append(c); continue }
            guard KeyStore.googleKey != nil, Metrics.value("lookupShops") < monthlyShopLookups else { continue }
            Metrics.count("lookupShops")
            let found = await GooglePlaces.text(c.name, latitude: c.latitude, longitude: c.longitude, radius: 300)
            let core = Matcher.coreName(c.name)
            guard let hit = found.first(where: {
                !$0.photo.isEmpty && Matcher.similarity(Matcher.coreName($0.name), core) >= 0.6
                    && Matcher.distance($0.latitude, $0.longitude, c.latitude, c.longitude) <= 250
            }) else { continue }
            var filled = c
            filled.photo = hit.photo
            filled.morePhotos = hit.morePhotos
            if filled.hours.isEmpty { filled.hours = hit.hours }
            out.append(filled)
        }
        return out
    }

    /// お店の写真を何枚か取り、料理が写っていそうな順に best 枚を返す（端末の見分けで並べる。外観・店内より料理を見比べたい）
    static func foodPhotos(of shop: PlaceCandidate, best: Int = 2) async -> [Data] {
        var scored: [(food: Double, data: Data)] = []
        for ref in ([shop.photo] + shop.morePhotos).filter({ !$0.isEmpty }).prefix(4) {
            if ref.hasPrefix("places/"), Metrics.value("googlePhotos") >= monthlyPhotoFetches { break }
            guard let data = await image(ref), let ui = UIImage(data: data) else { continue }
            let food = await Task.detached(priority: .utility) { PhotoVision.look(ui).food }.value
            scored.append((food, data))
        }
        return scored.sorted { $0.food > $1.food }.prefix(best).map(\.data)
    }

    /// 見比べてもらう。合うお店があれば、そのお店と答えを返す
    static func ask(food: [Data], shops: [PlaceCandidate]) async throws -> (shop: PlaceCandidate, answer: Answer)? {
        guard ClaudeLink.isReady else { throw ClaudeError.noKey }
        guard Spend.canSpend else { throw ClaudeError.capped }
        var named: [(shop: PlaceCandidate, photos: [Data])] = []
        for shop in shops {
            let photos = await foodPhotos(of: shop)
            if !photos.isEmpty { named.append((shop, photos)) }
        }
        guard !named.isEmpty, !food.isEmpty else { return nil }
        var content: [[String: Any]] = [["type": "text", "text": "食事の写真:"]]
        for data in food.prefix(2) { content.append(block(data)) }
        for (i, item) in named.enumerated() {
            content.append(["type": "text", "text": "候補 \(i): \(item.shop.name)（\(Int(item.shop.distance.rounded()))m）の紹介写真（\(item.photos.count) 枚）"])
            for data in item.photos { content.append(block(data)) }
        }
        content.append(["type": "text", "text": "食事の写真に一番合う候補の番号を選んでください。"])
        var body: [String: Any] = [
            "model": AIModel.main,
            "max_tokens": 2048,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        var data: Data
        do {
            data = try await ClaudeLink.send(ClaudeLink.request("/v1/messages", body: JSONSerialization.data(withJSONObject: body),
                                                                beta: "server-side-fallback-2026-07-01"))
        } catch ClaudeError.http(let code, _) where code == 400 {
            body.removeValue(forKey: "fallbacks")
            data = try await ClaudeLink.send(ClaudeLink.request("/v1/messages", body: JSONSerialization.data(withJSONObject: body)))
        }
        let (text, usd) = try ClaudeVision.textAndCost(data, model: AIModel.main)
        Spend.add(usd)
        Metrics.count("lookAlikes")
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)),
              answer.index >= 0, answer.index < named.count else { return nil }
        return (named[answer.index].shop, answer)
    }

    private static func block(_ data: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
    }

    /// 紹介写真を取ってきて、小さい JPEG にする
    static func image(_ ref: String) async -> Data? {
        var request: URLRequest
        if ref.hasPrefix("places/") {
            // Google の写真（1枚ごとに料金がかかるので、迷ったときにしか呼ばない）
            guard let key = KeyStore.googleKey,
                  let url = URL(string: "https://places.googleapis.com/v1/\(ref)/media?maxWidthPx=512&key=\(key)") else { return nil }
            request = URLRequest(url: url)
            request.setValue(Bundle.main.bundleIdentifier ?? "com.off53jub.gohan", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
            Metrics.count("googlePhotos")
        } else {
            guard ref.hasPrefix("https://"), let url = URL(string: ref) else { return nil }
            request = URLRequest(url: url)
        }
        request.timeoutInterval = 15
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let raw = result.0
        return await Task.detached(priority: .utility) { shrink(raw) }.value
    }

    static func shrink(_ data: Data, side: CGFloat = 512) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: 0.7)
    }
}
