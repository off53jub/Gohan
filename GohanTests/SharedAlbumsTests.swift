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

/// 2026-11-28 ういきょのごはんの取り込み
final class SharedAlbumImportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func photo(_ min: Double, _ lat: Double? = 35.69, _ lon: Double? = 139.70) -> SeenPhoto {
        SeenPhoto(id: "p\(min)", date: t0.addingTimeInterval(min * 60), latitude: lat, longitude: lon, accuracy: 10, food: 0.9, label: "ramen")
    }

    func testGroupsSplitByTimeAndPlace() {
        let g = SharedAlbums.groups([photo(0), photo(10), photo(120), photo(125, 35.80, 139.90)])
        XCTAssertEqual(g.map(\.count), [2, 1, 1])
    }

    func testWasThereByVisit() {
        let v = Visit(arrival: t0.addingTimeInterval(-600), departure: t0.addingTimeInterval(3600), latitude: 35.6901, longitude: 139.7001, accuracy: 20)
        XCTAssertTrue(SharedAlbums.wasThere(latitude: 35.69, longitude: 139.70, from: t0, to: t0, visits: [v], ownSpots: []))
        XCTAssertFalse(SharedAlbums.wasThere(latitude: 35.75, longitude: 139.70, from: t0, to: t0, visits: [v], ownSpots: []))
    }

    func testWasThereByOwnPhoto() {
        let near = [(date: t0.addingTimeInterval(50 * 60), latitude: 35.6905, longitude: 139.7003)]
        XCTAssertTrue(SharedAlbums.wasThere(latitude: 35.69, longitude: 139.70, from: t0, to: t0, visits: [], ownSpots: near))
        let late = [(date: t0.addingTimeInterval(90 * 60), latitude: 35.69, longitude: 139.70)]
        XCTAssertFalse(SharedAlbums.wasThere(latitude: 35.69, longitude: 139.70, from: t0, to: t0, visits: [], ownSpots: late))
    }
}

/// 2026-11-28 取り込みの見直し
final class UikyoReviewTests: XCTestCase {
    func testMergeKeepsNewest() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let old = [SharedAlbums.Logged(ids: ["a"], date: d, kind: .notThere), SharedAlbums.Logged(ids: ["b"], date: d.addingTimeInterval(60), kind: .added)]
        let new = [SharedAlbums.Logged(ids: ["a"], date: d, kind: .byHand)]
        let m = SharedAlbums.Logged.merged(old, new)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.first { $0.id == "a" }?.kind, .byHand)
        XCTAssertEqual(m.first?.id, "b")
    }

    func testNearAnniversary() {
        var c = DateComponents()
        c.year = 2025; c.month = 8; c.day = 3; c.hour = 19
        let date = Calendar.current.date(from: c)!
        let days = [Anniversary(name: "記念日", month: 8, day: 1)]
        XCTAssertTrue(UikyoReviewView.near(date, days))
        XCTAssertFalse(UikyoReviewView.near(date, [Anniversary(name: "誕生日", month: 8, day: 10)]))
    }
}
