import Foundation
import SwiftUI

// お店の候補の取り元を増やす（4。2026-11-24）。Apple のマップに加えて、鍵があれば Google・ホットペッパーも見る。
// どちらも本人が取った鍵を、この iPhone のキーチェーンにだけ置く。鍵が無ければ何もしない。

extension KeyStore {
    /// Google Maps Platform（Places API）の鍵（端末で入れたもの → 無ければ組み立てのときに入れたもの）
    static var googleKey: String? {
        get { readValue("com.off53jub.gohan.google") ?? builtIn("GooglePlacesKey") }
        set { writeValue("com.off53jub.gohan.google", newValue) }
    }

    /// リクルート WEBサービス（ホットペッパーグルメ）の鍵（端末で入れたもの → 無ければ組み立てのときに入れたもの）
    static var hotpepperKey: String? {
        get { readValue("com.off53jub.gohan.hotpepper") ?? builtIn("HotPepperKey") }
        set { writeValue("com.off53jub.gohan.hotpepper", newValue) }
    }

    /// 組み立てのときに CI が入れた鍵（Info.plist。入っていなければ nil）
    static func builtIn(_ name: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }
}

extension PlaceFinder {
    /// 近くのお店（Apple のマップ＋ホットペッパー）。Google は、ここで見つからないときだけ別に呼ぶ（本人の希望。2026-11-24）
    /// Yahoo! ローカルサーチも足した（日本の小さなお店に強い・無料。2026-11-26）
    static func nearbyAll(latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        async let apple = nearby(latitude: latitude, longitude: longitude, radius: radius)
        async let pepper = HotPepper.search(keyword: nil, latitude: latitude, longitude: longitude, radius: radius)
        async let yahoo = YahooLocal.search(query: nil, latitude: latitude, longitude: longitude, radius: radius)
        return merge([await apple, await pepper, await yahoo])
    }

    /// 名前で探す（Apple のマップ＋ホットペッパー＋Yahoo!）
    static func searchAll(_ query: String, latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        async let apple = search(query, latitude: latitude, longitude: longitude, radius: radius)
        async let pepper = HotPepper.search(keyword: query, latitude: latitude, longitude: longitude, radius: radius)
        async let yahoo = YahooLocal.search(query: query, latitude: latitude, longitude: longitude, radius: radius)
        return merge([await apple, await pepper, await yahoo])
    }

    /// 名前で探す。Apple・ホットペッパーで見つからなければ Google でも探す
    static func searchWithFallback(_ query: String, latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        let first = await searchAll(query, latitude: latitude, longitude: longitude, radius: radius)
        if !first.isEmpty { return first }
        return await GooglePlaces.text(query, latitude: latitude, longitude: longitude, radius: radius)
    }
}

/// Google のお店の情報（Places API (New)）
enum GooglePlaces {
    // 電話番号でもう上の料金の段なので、営業時間と写真を足しても段は変わらない（写真そのものを取るときは別料金）
    static let fields = "places.displayName,places.formattedAddress,places.location,places.primaryType,places.nationalPhoneNumber,places.regularOpeningHours,places.photos"

    static func nearby(latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        let body: [String: Any] = [
            "includedTypes": ["restaurant", "cafe", "bakery", "bar", "meal_takeaway"],
            "maxResultCount": 20,
            "rankPreference": "DISTANCE",
            "languageCode": "ja",
            "locationRestriction": ["circle": ["center": ["latitude": latitude, "longitude": longitude], "radius": min(radius, 50_000)]],
        ]
        return await call("https://places.googleapis.com/v1/places:searchNearby", body: body, latitude: latitude, longitude: longitude)
    }

    static func text(_ query: String, latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        let body: [String: Any] = [
            "textQuery": query,
            "languageCode": "ja",
            "maxResultCount": 10,
            "locationBias": ["circle": ["center": ["latitude": latitude, "longitude": longitude], "radius": min(radius, 50_000)]],
        ]
        let found = await call("https://places.googleapis.com/v1/places:searchText", body: body, latitude: latitude, longitude: longitude)
        return found.filter { $0.distance <= radius * 1.5 }
    }

    private static func call(_ url: String, body: [String: Any], latitude: Double, longitude: Double) async -> [PlaceCandidate] {
        guard let key = KeyStore.googleKey, let endpoint = URL(string: url),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fields, forHTTPHeaderField: "X-Goog-FieldMask")
        // 鍵を「iOS アプリ」で制限したときに要る印
        request.setValue(Bundle.main.bundleIdentifier ?? "com.off53jub.gohan", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = data
        guard let result = try? await URLSession.shared.data(for: request) else {
            note(problem: "つながりませんでした")
            return []
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 失敗が見えないと「本当に Google を使っているのか」が分からないので、理由を残す（作る人のメニューで見る）
            let message = ((try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            note(problem: "HTTP \(status) \(message.prefix(120))")
            return []
        }
        Metrics.count("googleCalls")
        return parse(result.0, latitude: latitude, longitude: longitude)
    }

    /// いちばん最近の失敗（日時と理由）。無ければ nil
    static var lastProblem: String? { UserDefaults.standard.string(forKey: "googleLastProblem") }

    private static func note(problem: String) {
        Metrics.count("googleErrors")
        let stamp = Date().formatted(.dateTime.month().day().hour().minute())
        UserDefaults.standard.set("\(stamp) \(problem)", forKey: "googleLastProblem")
    }

    static func parse(_ data: Data, latitude: Double, longitude: Double) -> [PlaceCandidate] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let places = json["places"] as? [[String: Any]] else { return [] }
        return places.compactMap { p in
            guard let name = (p["displayName"] as? [String: Any])?["text"] as? String,
                  let loc = p["location"] as? [String: Any],
                  let lat = (loc["latitude"] as? NSNumber)?.doubleValue, let lon = (loc["longitude"] as? NSNumber)?.doubleValue else { return nil }
            var address = p["formattedAddress"] as? String ?? ""
            if address.hasPrefix("日本、") { address = String(address.dropFirst(3)) }
            var c = PlaceCandidate(name: name, address: address, category: "google:" + (p["primaryType"] as? String ?? ""),
                                   latitude: lat, longitude: lon, distance: Matcher.distance(latitude, longitude, lat, lon),
                                   phone: p["nationalPhoneNumber"] as? String ?? "")
            if let periods = (p["regularOpeningHours"] as? [String: Any])?["periods"] as? [[String: Any]] {
                c.hours = OpenHours.googleText(periods)
            }
            if let photos = p["photos"] as? [[String: Any]] {
                let refs = photos.compactMap { $0["name"] as? String }
                c.photo = refs.first ?? ""
                c.morePhotos = Array(refs.dropFirst().prefix(4))
            }
            return c
        }
    }
}

/// ホットペッパーグルメ（リクルート WEBサービス）
enum HotPepper {
    static func search(keyword: String?, latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        guard let key = KeyStore.hotpepperKey,
              var c = URLComponents(string: "https://webservice.recruit.co.jp/hotpepper/gourmet/v1/") else { return [] }
        // 範囲: 1=300m 2=500m 3=1000m 4=2000m 5=3000m
        let range = radius <= 300 ? 1 : radius <= 500 ? 2 : radius <= 1000 ? 3 : radius <= 2000 ? 4 : 5
        var items = [
            URLQueryItem(name: "key", value: key), URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude)), URLQueryItem(name: "range", value: String(range)),
            URLQueryItem(name: "count", value: "30"), URLQueryItem(name: "format", value: "json"),
        ]
        if let keyword, !keyword.isEmpty { items.append(URLQueryItem(name: "keyword", value: keyword)) }
        c.queryItems = items
        guard let url = c.url, let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        Metrics.count("hotpepperCalls")
        return parse(result.0, latitude: latitude, longitude: longitude)
    }

    static func parse(_ data: Data, latitude: Double, longitude: Double) -> [PlaceCandidate] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [String: Any], let shops = results["shop"] as? [[String: Any]] else { return [] }
        func number(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        return shops.compactMap { s in
            guard let name = s["name"] as? String, let lat = number(s["lat"]), let lon = number(s["lng"]) else { return nil }
            let genre = (s["genre"] as? [String: Any])?["name"] as? String ?? ""
            var c = PlaceCandidate(name: name, address: s["address"] as? String ?? "", category: genre.isEmpty ? "" : "genre:" + genre,
                                   latitude: lat, longitude: lon, distance: Matcher.distance(latitude, longitude, lat, lon))
            c.hours = s["open"] as? String ?? ""
            c.closedDays = s["close"] as? String ?? ""
            let photo = s["photo"] as? [String: Any]
            let pc = (photo?["pc"] as? [String: Any])?["l"] as? String
            let mobile = (photo?["mobile"] as? [String: Any])?["l"] as? String
            c.photo = pc ?? mobile ?? ""
            return c
        }
    }
}

/// 迷ったときだけ、AI にネットで確かめてもらう（3）
enum WebCheck {
    struct Hint {
        var area: String
        var nameSeen: String
        var genre: String
        var dishes: [String]
        var candidates: [String]
        var lines: [String]
    }

    struct Answer: Equatable {
        var name: String
        var confidence: Double
    }

    static let system = """
    あなたは、食事の写真の記録から、どの飲食店で食べたかを確かめる係です。ウェブ検索を使って、実在するお店を1つに絞ります。
    手がかり（街・写真から読めた文字・料理のジャンル・近くのお店の候補）に合うお店を探し、店名がはっきりしたら答えます。
    答えは最後に、次の形の JSON だけを書きます（前後に説明を書かない）:
    {"name": "お店の正式な名前（分からなければ空）", "confidence": 0〜1の数}
    検索で見つからない・決め手が無いときは、name を空、confidence を 0 にします。当てずっぽうで答えません。
    """

    static func ask(_ hint: Hint) async throws -> Answer? {
        guard ClaudeLink.isReady else { throw ClaudeError.noKey }
        guard Spend.canSpend else { throw ClaudeError.capped }
        var text = "街: \(hint.area)\n料理のジャンル: \(hint.genre)\n"
        if !hint.dishes.isEmpty { text += "料理: \(hint.dishes.joined(separator: "、"))\n" }
        if !hint.nameSeen.isEmpty { text += "写真から読めた店名: \(hint.nameSeen)\n" }
        if !hint.candidates.isEmpty { text += "近くのお店の候補: \(hint.candidates.joined(separator: "、"))\n" }
        if !hint.lines.isEmpty { text += "写真から読めた文字（読み違いを含む）: \(hint.lines.joined(separator: " / "))\n" }
        var body: [String: Any] = [
            "model": AIModel.main,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": text]],
            "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 3,
                       "user_location": ["type": "approximate", "country": "JP"]]],
            "output_config": ["effort": "medium"],
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
        Metrics.count("webChecks")
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
              let obj = (try? JSONSerialization.jsonObject(with: Data(text[start.lowerBound..<end.upperBound].utf8))) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return (nil, usd) }
        let confidence = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0
        return (Answer(name: name, confidence: confidence), usd)
    }
}

/// ホットペッパーの情報を使うときの表示（ご利用案内のテキスト形式。2026-11-24 に確認）
struct HotPepperCredit: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Powered by")
            Link("ホットペッパーグルメ Webサービス", destination: URL(string: "https://webservice.recruit.co.jp/")!)
        }
        .font(.caption)
        .foregroundStyle(Ink.hai)
    }
}
