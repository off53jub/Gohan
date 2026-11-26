import SwiftData
import XCTest
@testable import Gohan

/// 2026-11-25 画像検索・お店の写真の見比べ
final class ImageSearchTests: XCTestCase {
    private func shop(_ name: String) -> PlaceCandidate {
        PlaceCandidate(name: name, address: "", category: "", latitude: 35.69, longitude: 139.70, distance: 30)
    }

    func testParsesWebDetection() throws {
        let json = """
        {"responses":[{"webDetection":{
          "webEntities":[{"entityId":"x","score":0.8,"description":"Tsukemen"}],
          "pagesWithMatchingImages":[{"url":"https://tabelog.com/a","pageTitle":"<b>麺屋こもれび</b> - 新宿/ラーメン [食べログ]"}],
          "bestGuessLabels":[{"label":"つけ麺"}]}}]}
        """
        let result = try XCTUnwrap(ImageSearch.parse(Data(json.utf8)))
        XCTAssertEqual(result.titles, ["麺屋こもれび - 新宿/ラーメン [食べログ]"])
        XCTAssertEqual(result.entities, ["Tsukemen", "つけ麺"])
    }

    func testEmptyResponseIsNotAnError() throws {
        let result = try XCTUnwrap(ImageSearch.parse(Data(#"{"responses":[{}]}"#.utf8)))
        XCTAssertTrue(result.isEmpty)
    }

    func testMatchesCandidateNamedInPageTitle() {
        let result = ImageSearch.Result(titles: ["麺屋こもれび - 新宿/ラーメン [食べログ]"], entities: [])
        let hit = ImageSearch.match(result, candidates: [shop("すし太郎"), shop("麺屋こもれび 新宿店")])
        XCTAssertEqual(hit?.name, "麺屋こもれび 新宿店")
        XCTAssertNil(ImageSearch.match(result, candidates: [shop("すし太郎")]))
        XCTAssertNil(ImageSearch.match(ImageSearch.Result(), candidates: [shop("すし太郎")]))
    }

    // 前の版で保存した候補（2 枚目からの写真が無い）も読める
    func testOldCandidatesDecodeWithoutMorePhotos() throws {
        let old = #"{"name":"店","address":"","category":"","latitude":35.6,"longitude":139.7,"distance":10,"photo":"places/a/photos/b"}"#
        let c = try JSONDecoder().decode(PlaceCandidate.self, from: Data(old.utf8))
        XCTAssertEqual(c.photo, "places/a/photos/b")
        XCTAssertEqual(c.morePhotos, [])
    }

    func testGooglePlacesKeepsSeveralPhotos() {
        let json = """
        {"places":[{"id":"ChIJabc","displayName":{"text":"麺屋こもれび"},"location":{"latitude":35.69,"longitude":139.70},
          "photos":[{"name":"p/1"},{"name":"p/2"},{"name":"p/3"}]}]}
        """
        let list = GooglePlaces.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(list.first?.photo, "p/1")
        XCTAssertEqual(list.first?.morePhotos, ["p/2", "p/3"])
        // Google の決まりで、ずっと残してよいのは place ID だけ（見つけ直しに使う）
        XCTAssertEqual(list.first?.googleID, "ChIJabc")
    }

    @MainActor
    func testGooglePlaceKeepsItsIDAndIsMarked() throws {
        let container = try ModelContainer(for: Place.self, Meal.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        var c = PlaceCandidate(name: "麺屋こもれび", address: "", category: "google:ramen_restaurant", latitude: 35.69, longitude: 139.70, distance: 0)
        c.googleID = "ChIJabc"
        let place = Place(candidate: c, date: Date())
        context.insert(place)
        XCTAssertTrue(place.fromGoogle)
        XCTAssertEqual(place.googleID, "ChIJabc")
        XCTAssertEqual(place.candidate.googleID, "ChIJabc")
        let apple = Place(candidate: PlaceCandidate(name: "a", address: "", category: "MKPOICategoryRestaurant", latitude: 0, longitude: 0, distance: 0), date: Date())
        context.insert(apple)
        XCTAssertFalse(apple.fromGoogle)
    }
}
