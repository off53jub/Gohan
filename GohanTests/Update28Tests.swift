import SwiftData
import XCTest
@testable import Gohan

/// 2026-11-28 大型アップデートの第 1 弾
final class Update28Tests: XCTestCase {
    private func shop(_ name: String, distance: Double = 30, category: String = "MKPOICategoryRestaurant", score: Double = 0.5) -> PlaceCandidate {
        PlaceCandidate(name: name, address: "", category: category, latitude: 0, longitude: 0, distance: distance, score: score)
    }

    // 大6
    func testRetroSearchPicksTheOnlyRamenShopNearby() {
        let found = [shop("麺屋はるか", distance: 50), shop("カフェ こもれび", distance: 20, category: "MKPOICategoryCafe")]
        XCTAssertEqual(RetroSearch.pick(found, genre: "ラーメン")?.name, "麺屋はるか")
    }

    func testRetroSearchDoesNotPickWhenTwoRamenShops() {
        let found = [shop("麺屋はるか", distance: 50), shop("らーめん 一番", distance: 120)]
        XCTAssertNil(RetroSearch.pick(found, genre: "ラーメン"))
    }

    func testRetroSearchDoesNotPickFarShop() {
        XCTAssertNil(RetroSearch.pick([shop("麺屋はるか", distance: 120)], genre: "ラーメン"))
    }

    func testRetroSearchTargets() {
        XCTAssertTrue(RetroSearch.wanted(hasPlace: false, hasLocation: true, eatenOut: true, spot: "", tried: false))
        XCTAssertFalse(RetroSearch.wanted(hasPlace: true, hasLocation: true, eatenOut: true, spot: "", tried: false))
        XCTAssertFalse(RetroSearch.wanted(hasPlace: false, hasLocation: false, eatenOut: true, spot: "", tried: false))
        XCTAssertFalse(RetroSearch.wanted(hasPlace: false, hasLocation: true, eatenOut: true, spot: "home", tried: false))
        XCTAssertFalse(RetroSearch.wanted(hasPlace: false, hasLocation: true, eatenOut: true, spot: "", tried: true))
    }

    // 大11
    func testHabitsTopNeedsEnoughMealsAndShare() {
        XCTAssertEqual(Habits.top(Array(repeating: "ラーメン", count: 20) + Array(repeating: "カフェ", count: 10))?.genre, "ラーメン")
        XCTAssertNil(Habits.top(Array(repeating: "ラーメン", count: 10)))
        XCTAssertNil(Habits.top(["ラーメン", "カフェ", "寿司", "焼肉"].flatMap { Array(repeating: $0, count: 10) }))
    }

    func testHabitsLiftOnlyWhenPhotoGenreUnknown() {
        let ranked = [shop("カフェ こもれび", category: "MKPOICategoryCafe", score: 0.5), shop("麺屋はるか", score: 0.47)]
        XCTAssertEqual(Habits.apply(ranked, photoGenre: nil, habit: "ラーメン").first?.name, "麺屋はるか")
        XCTAssertEqual(Habits.apply(ranked, photoGenre: "スイーツ", habit: "ラーメン").first?.name, "カフェ こもれび")
        XCTAssertEqual(Habits.apply(ranked, photoGenre: nil, habit: nil).first?.name, "カフェ こもれび")
    }

    // 大9
    func testOldAccuracyRowsStillRead() throws {
        let old = #"[{"id":"8A949250-BD23-439C-ABF6-AEFD603DC508","date":0,"kind":"hit","source":"pc","rank":0,"label":"","before":"a","after":"a"}]"#
        let rows = try JSONDecoder().decode([AccuracyEntry].self, from: Data(old.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].features)
    }

    func testFeaturesKeepTheBreakdown() {
        var c = shop("麺屋はるか", distance: 42.37, score: 0.61234)
        c.textHit = 0.456
        c.visited = true
        let f = CandidateFeature(c)
        XCTAssertEqual(f.distance, 42.4)
        XCTAssertEqual(f.textHit, 0.46)
        XCTAssertEqual(f.score, 0.612)
        XCTAssertTrue(f.visited)
        XCTAssertEqual(f.genre, "ラーメン")
        XCTAssertEqual(CandidateFeature.list(Array(repeating: c, count: 12)).count, 8)
    }

    // 大7
    func testQuietTitleNeverSaysUnknown() {
        XCTAssertEqual(Meal.quietTitle(dishes: ["醤油ラーメン"], genre: "ラーメン"), "醤油ラーメン")
        XCTAssertEqual(Meal.quietTitle(dishes: [], genre: "ラーメン"), "ラーメン")
        XCTAssertEqual(Meal.quietTitle(dishes: [], genre: "その他"), "外で食べたごはん")
    }

    // 大20
    func testMonthlyNoteOnlyEarlyInTheMonthAndOnce() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let dec3 = cal.date(from: DateComponents(year: 2026, month: 12, day: 3, hour: 9))!
        let dec10 = cal.date(from: DateComponents(year: 2026, month: 12, day: 10, hour: 9))!
        let jan2 = cal.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9))!
        XCTAssertEqual(MonthlyNote.due(now: dec3, lastSent: nil, calendar: cal), "2026-11")
        XCTAssertNil(MonthlyNote.due(now: dec3, lastSent: "2026-11", calendar: cal))
        XCTAssertNil(MonthlyNote.due(now: dec10, lastSent: nil, calendar: cal))
        XCTAssertEqual(MonthlyNote.due(now: jan2, lastSent: "2026-11", calendar: cal), "2026-12")
        XCTAssertEqual(MonthlyNote.text(month: 11, meals: 12, shops: 8, first: 3), "11月は 12 食・8 軒（はじめて 3 軒）。まとめを見てみませんか。")
    }

    // 大21
    func testGenreBookCounts() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let d24 = cal.date(from: DateComponents(year: 2024, month: 5, day: 1))!
        let d25 = cal.date(from: DateComponents(year: 2025, month: 5, day: 1))!
        let book = GenreBook.make(dates: [d24, d25, d25], shops: ["はるか", "はるか", nil], regions: ["東京都", "千葉県", "東京都"], calendar: cal)
        XCTAssertEqual(book.total, 3)
        XCTAssertEqual(book.years.map(\.name), ["2025", "2024"])
        XCTAssertEqual(book.years.first?.count, 2)
        XCTAssertEqual(book.shops, [GenreBook.Row(name: "はるか", count: 2)])
        XCTAssertEqual(book.regions.first, GenreBook.Row(name: "東京都", count: 2))
    }

    // 大22
    func testHangLine() {
        XCTAssertNil(Slowness.hang(0.1))
        XCTAssertEqual(Slowness.hang(1.2), 1.2)
    }

    // 大27: 写しから戻せる
    @MainActor
    func testBackupRoundTrip() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let first = try ModelContainer(for: Meal.self, Place.self, configurations: config)
        let place = Place(candidate: PlaceCandidate(name: "麺屋はるか", address: "東京都", category: "", latitude: 35.69, longitude: 139.70, distance: 0),
                          date: Date(timeIntervalSince1970: 1_700_000_000))
        place.wantAgain = true
        first.mainContext.insert(place)
        let meal = Meal(date: Date(timeIntervalSince1970: 1_700_000_000), endDate: Date(timeIntervalSince1970: 1_700_000_600),
                        photoIDs: ["test-photo"], latitude: 35.69, longitude: 139.70)
        meal.genre = "ラーメン"
        meal.dishes = ["醤油ラーメン"]
        meal.place = place
        first.mainContext.insert(meal)
        try first.mainContext.save()
        guard let url = Backup.write(context: first.mainContext) else { return XCTFail("書き出せなかった") }

        let second = try ModelContainer(for: Meal.self, Place.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        XCTAssertEqual(try Backup.restore(from: url, context: second.mainContext), 1)
        let back = try second.mainContext.fetch(FetchDescriptor<Meal>())
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.id, meal.id)
        XCTAssertEqual(back.first?.genre, "ラーメン")
        XCTAssertEqual(back.first?.dishes, ["醤油ラーメン"])
        XCTAssertEqual(back.first?.place?.name, "麺屋はるか")
        XCTAssertEqual(back.first?.place?.wantAgain, true)
        // 2 回戻しても増えない
        XCTAssertEqual(try Backup.restore(from: url, context: second.mainContext), 0)
    }
}
