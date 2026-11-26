import Foundation
import SwiftUI

// お店の候補の取り元をさらに増やす（本人「全部入れよう」2026-11-26）。
// ・Yahoo! ローカルサーチ: 日本の小さなお店に強い。無料（1 日 5 万回まで）。いつも使う
// ・OpenStreetMap: 料理の種類（cuisine）の印がある。無料・登録なし。迷ったときだけ
// ・Foursquare: 迷ったときだけ。料金があるので月の上限つき
// ・Google のクチコミ: 写真から読んだ料理名が、候補のお店のクチコミに出てくるか。迷ったときだけ・月の上限つき

extension KeyStore {
    /// Yahoo! JAPAN の Client ID（組み立てのときに CI が入れる）
    static var yahooAppID: String? { builtIn("YahooAppID") }
    /// Foursquare の Service API key（組み立てのときに CI が入れる）
    static var foursquareKey: String? { builtIn("FoursquareKey") }
}

/// Yahoo! ローカルサーチ API（YOLP）。クレジットの表示が要る（YahooCredit）
enum YahooLocal {
    static func search(query: String?, latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        guard let appID = KeyStore.yahooAppID,
              var c = URLComponents(string: "https://map.yahooapis.jp/search/local/V1/localSearch") else { return [] }
        var items = [
            URLQueryItem(name: "appid", value: appID),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude)),
            URLQueryItem(name: "dist", value: String(format: "%.2f", max(0.1, min(20, radius / 1000)))),
            URLQueryItem(name: "gc", value: "01"),   // グルメ
            URLQueryItem(name: "sort", value: "dist"),
            URLQueryItem(name: "results", value: "30"),
            URLQueryItem(name: "output", value: "json"),
        ]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        c.queryItems = items
        guard let url = c.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        Metrics.count("yahooCalls")
        return parse(data, latitude: latitude, longitude: longitude)
    }

    static func parse(_ data: Data, latitude: Double, longitude: Double) -> [PlaceCandidate] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = json["Feature"] as? [[String: Any]] else { return [] }
        return features.compactMap { f in
            guard let name = f["Name"] as? String, !name.isEmpty,
                  let coords = (f["Geometry"] as? [String: Any])?["Coordinates"] as? String else { return nil }
            // "経度,緯度" の順
            let parts = coords.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { return nil }
            let lon = parts[0], lat = parts[1]
            let p = f["Property"] as? [String: Any] ?? [:]
            // ジャンルは 1 つでも配列で来ることがあるので、どちらでも読む
            var genres: [String] = []
            if let list = p["Genre"] as? [[String: Any]] { genres = list.compactMap { $0["Name"] as? String } }
            if let one = p["Genre"] as? [String: Any], let n = one["Name"] as? String { genres = [n] }
            var address = p["Address"] as? String ?? ""
            if let building = (p["Building"] as? [String: Any])?["Name"] as? String, !building.isEmpty, !address.contains(building) {
                address += " " + building
            }
            return PlaceCandidate(name: name, address: address, category: "yahoo:" + genres.joined(separator: " "),
                                  latitude: lat, longitude: lon, distance: Matcher.distance(latitude, longitude, lat, lon),
                                  phone: p["Tel1"] as? String ?? "")
        }
    }
}

/// OpenStreetMap（Overpass）。混みやすい無料のサーバーなので、迷ったときだけ・短く待つ
enum OSMPlaces {
    static let monthlyCap = 300
    static let servers = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter"]

    static func nearby(latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        guard Metrics.value("osmCalls") < monthlyCap else { return [] }
        let r = Int(min(500, max(80, radius)))
        let q = """
        [out:json][timeout:12];
        (nwr(around:\(r),\(latitude),\(longitude))["amenity"~"^(restaurant|cafe|fast_food|bar|pub|food_court|ice_cream)$"]["name"];
         nwr(around:\(r),\(latitude),\(longitude))["shop"~"^(bakery|confectionery|pastry|deli|tea|coffee)$"]["name"];);
        out center tags;
        """
        Metrics.count("osmCalls")
        for server in servers {
            guard let url = URL(string: server) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("gohan-ios/1.0", forHTTPHeaderField: "User-Agent")
            request.httpBody = "data=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return parse(data, latitude: latitude, longitude: longitude)
            }
        }
        return []
    }

    static func parse(_ data: Data, latitude: Double, longitude: Double) -> [PlaceCandidate] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap { e in
            let tags = e["tags"] as? [String: String] ?? [:]
            guard let name = tags["name:ja"] ?? tags["name"] else { return nil }
            let center = e["center"] as? [String: Any]
            guard let lat = (e["lat"] as? NSNumber ?? center?["lat"] as? NSNumber)?.doubleValue,
                  let lon = (e["lon"] as? NSNumber ?? center?["lon"] as? NSNumber)?.doubleValue else { return nil }
            let kind = tags["cuisine"] ?? tags["amenity"] ?? tags["shop"] ?? ""
            let address = [tags["addr:city"], tags["addr:street"], tags["addr:housenumber"]].compactMap { $0 }.joined()
            return PlaceCandidate(name: name, address: address, category: "osm:" + kind,
                                  latitude: lat, longitude: lon, distance: Matcher.distance(latitude, longitude, lat, lon))
        }
    }
}

/// Foursquare Places API（新しい places-api.foursquare.com）。迷ったときだけ・月の上限つき
enum FoursquarePlaces {
    static let monthlyCap = 300

    static func nearby(latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        guard let key = KeyStore.foursquareKey, Metrics.value("foursquareCalls") < monthlyCap,
              var c = URLComponents(string: "https://places-api.foursquare.com/places/search") else { return [] }
        c.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "radius", value: String(Int(min(1000, max(80, radius))))),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "sort", value: "DISTANCE"),
            // 料金の安い Pro の項目だけ
            URLQueryItem(name: "fields", value: "fsq_place_id,name,latitude,longitude,distance,categories,location,tel"),
        ]
        guard let url = c.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-06-17", forHTTPHeaderField: "X-Places-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Metrics.count("foursquareCalls")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data, latitude: latitude, longitude: longitude)
    }

    static func parse(_ data: Data, latitude: Double, longitude: Double) -> [PlaceCandidate] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let name = r["name"] as? String,
                  let lat = (r["latitude"] as? NSNumber)?.doubleValue, let lon = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
            let categories = (r["categories"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let address = (r["location"] as? [String: Any])?["formatted_address"] as? String ?? ""
            return PlaceCandidate(name: name, address: address, category: "fsq:" + categories.joined(separator: " "),
                                  latitude: lat, longitude: lon, distance: Matcher.distance(latitude, longitude, lat, lon),
                                  phone: r["tel"] as? String ?? "")
        }
    }
}

/// Google のクチコミで、写真から読んだ料理名を候補のお店と突き合わせる（迷ったときだけ・月の上限つき）
enum ReviewMatch {
    static let monthlyCap = 100

    /// 料理名から、どこのお店にもある言葉（ラーメン・醤油など）を外した、決め手になりそうな言葉
    static func keywords(dishes: [String], lines: [String] = []) -> [String] {
        let common = ["ラーメン", "らーめん", "つけ麺", "そば", "うどん", "醤油", "味噌", "塩", "豚骨", "とんこつ", "定食", "セット",
                      "ランチ", "ライス", "ご飯", "大盛り", "並", "特製", "味玉", "チャーシュー", "餃子", "ビール", "コーヒー", "ケーキ"]
        var out: [String] = []
        for dish in dishes {
            var word = dish
            for c in common { word = word.replacingOccurrences(of: c, with: " ") }
            for part in word.split(whereSeparator: { " （）()・、".contains($0) }) where part.count >= 2 {
                out.append(String(part))
            }
        }
        return Array(NSOrderedSet(array: out).array.compactMap { $0 as? String }.prefix(6))
    }

    /// 候補ごとにクチコミを読み、決め手の言葉が出てくるお店が 1 軒だけならそれを返す
    static func pick(candidates: [PlaceCandidate], keywords: [String], latitude: Double, longitude: Double) async
        -> (shop: PlaceCandidate, word: String)? {
        guard !keywords.isEmpty, KeyStore.googleKey != nil else { return nil }
        var hits: [(PlaceCandidate, String)] = []
        for c in candidates.prefix(4) {
            guard Metrics.value("reviewChecks") < monthlyCap else { break }
            Metrics.count("reviewChecks")
            let texts = await GooglePlaces.reviews(name: c.name, latitude: c.latitude, longitude: c.longitude)
            if let word = keywords.first(where: { w in texts.contains { $0.contains(w) } }) { hits.append((c, word)) }
        }
        guard hits.count == 1, let hit = hits.first else { return nil }
        return (shop: hit.0, word: hit.1)
    }
}

extension GooglePlaces {
    /// お店のクチコミの文（名前と場所で探し、いちばん合うお店のもの）。料金が高いので ReviewMatch からだけ呼ぶ
    static func reviews(name: String, latitude: Double, longitude: Double) async -> [String] {
        guard let key = KeyStore.googleKey, let url = URL(string: "https://places.googleapis.com/v1/places:searchText") else { return [] }
        let body: [String: Any] = [
            "textQuery": name, "languageCode": "ja", "maxResultCount": 3,
            "locationBias": ["circle": ["center": ["latitude": latitude, "longitude": longitude], "radius": 300]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("places.displayName,places.location,places.reviews,places.editorialSummary", forHTTPHeaderField: "X-Goog-FieldMask")
        request.setValue(Bundle.main.bundleIdentifier ?? "com.off53jub.gohan", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return reviewTexts(data, name: name, latitude: latitude, longitude: longitude)
    }

    static func reviewTexts(_ data: Data, name: String, latitude: Double, longitude: Double) -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let places = json["places"] as? [[String: Any]] else { return [] }
        let core = Matcher.coreName(name)
        guard let place = places.first(where: { p in
            let n = ((p["displayName"] as? [String: Any])?["text"] as? String) ?? ""
            guard let loc = p["location"] as? [String: Any], let la = (loc["latitude"] as? NSNumber)?.doubleValue,
                  let lo = (loc["longitude"] as? NSNumber)?.doubleValue else { return false }
            return Matcher.similarity(Matcher.coreName(n), core) >= 0.6 && Matcher.distance(la, lo, latitude, longitude) <= 300
        }) else { return [] }
        var texts: [String] = []
        for r in place["reviews"] as? [[String: Any]] ?? [] {
            if let t = (r["originalText"] as? [String: Any])?["text"] as? String { texts.append(t) }
            if let t = (r["text"] as? [String: Any])?["text"] as? String { texts.append(t) }
        }
        if let s = (place["editorialSummary"] as? [String: Any])?["text"] as? String { texts.append(s) }
        return texts
    }
}

/// Yahoo! のクレジット（規約で表示が要る）
struct YahooCredit: View {
    var body: some View {
        if KeyStore.yahooAppID != nil, let url = URL(string: "https://developer.yahoo.co.jp/sitemap/") {
            Link("Webサービス by Yahoo! JAPAN", destination: url)
                .font(.caption2)
        }
    }
}
