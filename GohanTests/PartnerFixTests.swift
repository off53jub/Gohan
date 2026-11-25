import XCTest
@testable import Gohan

/// 2026-11-26 ふたり帖の答えで自分の食事を補う
final class PartnerFixTests: XCTestCase {
    private func theirs(confidence: Double?, genre: String = "ラーメン", genreByHand: Bool? = nil, placeKey: String? = "k") -> PartnerMeal {
        PartnerMeal(id: UUID(), date: Date(), latitude: 35.69, longitude: 139.70, title: "", placeKey: placeKey,
                    placeName: "麺屋こもれび", address: "新宿", genre: genre, dishes: [], note: "", wantAgain: false, thumbnail: nil,
                    placeLatitude: 35.6901, placeLongitude: 139.7001, placeCategory: "restaurant",
                    confidence: confidence, genreByHand: genreByHand)
    }

    private func mine(confidence: Double, placeKey: String? = nil, genre: String = "ラーメン", genreByHand: Bool = false)
        -> (confidence: Double, hasPlace: Bool, placeKey: String?, genre: String, genreByHand: Bool, latitude: Double, longitude: Double) {
        (confidence, placeKey != nil, placeKey, genre, genreByHand, 35.69, 139.70)
    }

    func testTakesPartnersSurePlaceWhenIAmUnsure() {
        let change = PartnerFix.change(mine: mine(confidence: 0.4), theirs: theirs(confidence: 1))
        XCTAssertEqual(change?.place?.name, "麺屋こもれび")
        XCTAssertEqual(change?.placeConfidence, 0.9)
    }

    func testKeepsMyPlaceWhenPartnerIsUnsureOrIChoseIt() {
        XCTAssertNil(PartnerFix.change(mine: mine(confidence: 0.4), theirs: theirs(confidence: 0.6)))
        XCTAssertNil(PartnerFix.change(mine: mine(confidence: 1, placeKey: "other"), theirs: theirs(confidence: 1)))
        // 同じお店ならなにもしない
        XCTAssertNil(PartnerFix.change(mine: mine(confidence: 0.5, placeKey: "k"), theirs: theirs(confidence: 1)))
    }

    func testCopiesGenreOnlyWhenPartnerFixedItByHand() {
        XCTAssertEqual(PartnerFix.change(mine: mine(confidence: 1, placeKey: "k", genre: "丼"),
                                         theirs: theirs(confidence: 1, genreByHand: true))?.genre, "ラーメン")
        XCTAssertNil(PartnerFix.change(mine: mine(confidence: 1, placeKey: "k", genre: "丼"), theirs: theirs(confidence: 1)))
        XCTAssertNil(PartnerFix.change(mine: mine(confidence: 1, placeKey: "k", genre: "丼", genreByHand: true),
                                       theirs: theirs(confidence: 1, genreByHand: true)))
    }

    // 前の版のふたり帖のファイル（自信などが無い）も読める
    func testOldPartnerFileDecodes() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"title":"","genre":"ラーメン","dishes":[],"note":"","wantAgain":false}"#
        let meal = try JSONDecoder().decode(PartnerMeal.self, from: Data(old.utf8))
        XCTAssertNil(meal.confidence)
        XCTAssertNil(PartnerFix.change(mine: mine(confidence: 0.2), theirs: meal))
    }
}
