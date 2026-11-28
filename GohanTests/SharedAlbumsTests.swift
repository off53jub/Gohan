import XCTest
@testable import Gohan

/// 2026-11-28 「ういきょ」の共有アルバムを数える試し
final class SharedAlbumsTests: XCTestCase {
    func testAlbumNames() {
        XCTAssertTrue(SharedAlbums.matches("ういきょ 2025"))
        XCTAssertTrue(SharedAlbums.matches("ウイキョ旅行"))
        XCTAssertTrue(SharedAlbums.matches(" ういきょ"))
        XCTAssertFalse(SharedAlbums.matches("家族"))
        XCTAssertFalse(SharedAlbums.matches("う"))
    }

    func testTallyCountsOnlyFoodDetails() {
        var t = SharedAlbums.Tally(name: "ういきょ")
        let a = Date(timeIntervalSince1970: 1_000_000)
        let b = a.addingTimeInterval(3600)
        t.add(date: b, isFood: true, hasLocation: true, inMyMeal: true, mine: false)
        t.add(date: a, isFood: false, hasLocation: true, inMyMeal: true, mine: true)
        t.add(date: nil, isFood: true, hasLocation: false, inMyMeal: false, mine: true)
        XCTAssertEqual(t.photos, 3)
        XCTAssertEqual(t.food, 2)
        XCTAssertEqual(t.located, 1)
        XCTAssertEqual(t.duringMyMeal, 1)
        XCTAssertEqual(t.sameAsMine, 1)
        XCTAssertEqual(t.first, a)
        XCTAssertEqual(t.last, b)
    }

    func testInMealUsesMargin() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let spans = [(start, start.addingTimeInterval(1800))]
        XCTAssertTrue(SharedAlbums.inMeal(start.addingTimeInterval(-29 * 60), spans: spans))
        XCTAssertTrue(SharedAlbums.inMeal(start.addingTimeInterval(1800 + 29 * 60), spans: spans))
        XCTAssertFalse(SharedAlbums.inMeal(start.addingTimeInterval(-31 * 60), spans: spans))
    }
}
