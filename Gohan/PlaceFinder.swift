import CoreLocation
import Foundation
import MapKit

/// 写真の位置の近くの飲食店を、Apple のマップで探す（鍵も料金も要らない）
enum PlaceFinder {
    static let foodCategories: [MKPointOfInterestCategory] = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife, .foodMarket,
    ]

    /// 近くのお店（半径 radius m）
    static func nearby(latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: foodCategories)
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { candidate($0, from: center) }
        } catch {
            return []
        }
    }

    /// 名前で探す（看板・メニューの文字や、手で入れた名前で）
    static func search(_ query: String, latitude: Double, longitude: Double, radius: Double) async -> [PlaceCandidate] {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        request.resultTypes = .pointOfInterest
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { candidate($0, from: center) }.filter { $0.distance <= radius * 1.5 }
        } catch {
            return []
        }
    }

    private static func candidate(_ item: MKMapItem, from center: CLLocationCoordinate2D) -> PlaceCandidate? {
        guard let name = item.name, !name.isEmpty else { return nil }
        let coordinate = item.placemark.coordinate
        let distance = Matcher.distance(center.latitude, center.longitude, coordinate.latitude, coordinate.longitude)
        return PlaceCandidate(
            name: name,
            address: address(item.placemark),
            category: item.pointOfInterestCategory?.rawValue ?? "",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            distance: distance
        )
    }

    private static func address(_ p: MKPlacemark) -> String {
        [p.administrativeArea, p.locality, p.subLocality, p.thoroughfare, p.subThoroughfare]
            .compactMap { $0 }
            .reduce(into: [String]()) { list, part in if !list.contains(part) { list.append(part) } }
            .joined()
    }

    /// 近くの地名（「新宿」「渋谷区道玄坂」など）
    static func area(latitude: Double, longitude: Double) async -> String {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ja_JP")).first else {
            return ""
        }
        return mark.subLocality ?? mark.locality ?? mark.administrativeArea ?? ""
    }

    /// 候補を1つにまとめる（同じお店が別の探し方で2回出たとき）
    static func merge(_ lists: [[PlaceCandidate]]) -> [PlaceCandidate] {
        var seen: [String: PlaceCandidate] = [:]
        var order: [String] = []
        for list in lists {
            for c in list {
                let k = Matcher.normalize(c.name)
                if var old = seen[k] {
                    // 近いほうの位置を残し、「前に行った」はどちらかが付いていれば付ける
                    if c.distance < old.distance { old.distance = c.distance; old.latitude = c.latitude; old.longitude = c.longitude }
                    old.visited = old.visited || c.visited
                    if old.address.isEmpty { old.address = c.address }
                    if old.category.isEmpty { old.category = c.category }
                    seen[k] = old
                } else {
                    seen[k] = c
                    order.append(k)
                }
            }
        }
        return order.compactMap { seen[$0] }
    }

    static func openInMaps(name: String, latitude: Double, longitude: Double) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        item.name = name
        item.openInMaps()
    }
}
