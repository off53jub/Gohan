import Foundation
import SwiftData
import SwiftUI

/// Google から取ったお店を、Apple のマップ・ホットペッパー・OpenStreetMap で見つけ直して置きかえる（本人「A で」2026-11-26）。
/// Google の Places の決まり: 店名・住所は保存しない、緯度経度は 30 日まで、place ID はずっと残してよい。
/// → 見つけ直せたら、そちらの情報で保存し直す（Google の情報は消える）。
///   見つけ直せなければ place ID を残し、名前と位置は 30 日より前に Google から取り直す（Google のすすめる形）。
@MainActor
enum PlaceRehome {
    /// 名前と位置を取り直す間隔（30 日の決まりより少し短く）
    static let refreshDays = 25.0

    /// 同じお店を、保存してよい取り元（Apple・ホットペッパー・OpenStreetMap）で探す
    static func localCopy(name: String, latitude: Double, longitude: Double) async -> PlaceCandidate? {
        let core = Matcher.coreName(name)
        guard !core.isEmpty else { return nil }
        func best(_ list: [PlaceCandidate]) -> PlaceCandidate? {
            list.filter { !$0.category.hasPrefix("google:") }
                .filter { Matcher.distance($0.latitude, $0.longitude, latitude, longitude) <= 150 }
                .map { ($0, Matcher.similarity(Matcher.coreName($0.name), core)) }
                .filter { $0.1 >= 0.6 }
                .max { $0.1 < $1.1 }?.0
        }
        async let apple = PlaceFinder.search(name, latitude: latitude, longitude: longitude, radius: 300)
        async let pepper = HotPepper.search(keyword: name, latitude: latitude, longitude: longitude, radius: 300)
        if let found = best(await apple + (await pepper)) { return found }
        return best(await OSMPlaces.nearby(latitude: latitude, longitude: longitude, radius: 150))
    }

    /// 1 軒を置きかえる。見つけ直せたら true
    @discardableResult
    static func rehome(_ place: Place, context: ModelContext) async -> Bool {
        guard place.fromGoogle else { return false }
        if let local = await localCopy(name: place.name, latitude: place.latitude, longitude: place.longitude) {
            let key = local.key
            let same = (try? context.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.key == key })))?.first
            if let same, same !== place {
                // もう同じお店がある → 食事と印をそちらに移し、Google のほうを消す
                for meal in Array(place.meals) { meal.place = same }
                same.wantAgain = same.wantAgain || place.wantAgain
                same.wantToTry = same.wantToTry || place.wantToTry
                if same.note.isEmpty { same.note = place.note }
                if same.nextWish.isEmpty { same.nextWish = place.nextWish }
                same.firstVisit = min(same.firstVisit, place.firstVisit)
                context.delete(place)
            } else {
                place.key = key
                place.name = local.name
                place.address = local.address
                place.category = local.category
                place.latitude = local.latitude
                place.longitude = local.longitude
                place.phone = local.phone
                place.url = local.url
                place.googleID = ""
                place.googleFetchedAt = nil
            }
            try? context.save()
            Metrics.count("placesRehomed")
            return true
        }
        // 見つけ直せない → place ID を残し、名前と位置を Google から取り直す（前の版で ID を残していないお店は、ここで探す）
        if place.googleID.isEmpty {
            place.googleID = await GooglePlaces.findID(name: place.name, latitude: place.latitude, longitude: place.longitude) ?? ""
        }
        if !place.googleID.isEmpty, let fresh = await GooglePlaces.details(id: place.googleID) {
            place.name = fresh.name
            place.address = fresh.address
            place.latitude = fresh.latitude
            place.longitude = fresh.longitude
        }
        place.googleFetchedAt = Date()
        try? context.save()
        return false
    }

    /// まだ見つけ直していない・取り直しの時期が来た Google のお店を、少しずつ片づける（読み込みのたび）
    static func sweep(context: ModelContext, limit: Int = 15) async {
        let line = Date().addingTimeInterval(-refreshDays * 86_400)
        let places = ((try? context.fetch(FetchDescriptor<Place>())) ?? [])
            .filter { $0.fromGoogle && ($0.googleFetchedAt ?? .distantPast) < line }
        for place in places.prefix(limit) {
            if Task.isCancelled { break }
            await rehome(place, context: context)
        }
    }
}

extension GooglePlaces {
    /// 名前と場所から place ID だけを探す（料金の安い項目だけ）
    static func findID(name: String, latitude: Double, longitude: Double) async -> String? {
        let body: [String: Any] = [
            "textQuery": name, "languageCode": "ja", "maxResultCount": 3,
            "locationBias": ["circle": ["center": ["latitude": latitude, "longitude": longitude], "radius": 300]],
        ]
        guard let data = await simpleCall("https://places.googleapis.com/v1/places:searchText", method: "POST", body: body,
                                          fields: "places.id,places.displayName,places.location"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let places = json["places"] as? [[String: Any]] else { return nil }
        let core = Matcher.coreName(name)
        return places.first { p in
            let n = ((p["displayName"] as? [String: Any])?["text"] as? String) ?? ""
            return Matcher.similarity(Matcher.coreName(n), core) >= 0.6
        }?["id"] as? String
    }

    /// place ID から、今の名前・住所・位置を取る
    static func details(id: String) async -> (name: String, address: String, latitude: Double, longitude: Double)? {
        guard !id.contains("/"),
              let data = await simpleCall("https://places.googleapis.com/v1/places/\(id)", method: "GET", body: nil,
                                          fields: "id,displayName,formattedAddress,location"),
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = (p["displayName"] as? [String: Any])?["text"] as? String,
              let loc = p["location"] as? [String: Any],
              let lat = (loc["latitude"] as? NSNumber)?.doubleValue, let lon = (loc["longitude"] as? NSNumber)?.doubleValue else { return nil }
        var address = p["formattedAddress"] as? String ?? ""
        if address.hasPrefix("日本、") { address = String(address.dropFirst(3)) }
        return (name, address, lat, lon)
    }

    private static func simpleCall(_ url: String, method: String, body: [String: Any]?, fields: String) async -> Data? {
        guard let key = KeyStore.googleKey, let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fields, forHTTPHeaderField: "X-Goog-FieldMask")
        request.setValue(Bundle.main.bundleIdentifier ?? "com.off53jub.gohan", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        Metrics.count("googleCalls")
        return data
    }
}

/// Google から取った情報を見せるときのクレジット（Google の決まり）
struct GoogleCredit: View {
    var body: some View {
        Text("Google Maps").font(.caption2).foregroundStyle(.secondary)
    }
}
