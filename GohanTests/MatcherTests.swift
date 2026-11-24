import XCTest
@testable import Gohan

final class MatcherTests: XCTestCase {
    private func photo(_ id: String, minutes: Double, lat: Double? = 35.6900, lon: Double? = 139.7000, food: Double = 0.9) -> SeenPhoto {
        SeenPhoto(id: id, date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), latitude: lat, longitude: lon,
                  accuracy: 20, food: food, label: "ramen")
    }

    // MARK: 食事のまとめ方

    func testPhotosCloseInTimeAndPlaceBecomeOneMeal() {
        let groups = Matcher.groupMeals([photo("a", minutes: 0), photo("b", minutes: 10), photo("c", minutes: 35)])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["a", "b", "c"]])
    }

    func testLongGapSplitsMeals() {
        let groups = Matcher.groupMeals([photo("lunch", minutes: 0), photo("dinner", minutes: 6 * 60)])
        XCTAssertEqual(groups.count, 2)
    }

    func testFarAwayPhotoSplitsMeal() {
        // 10 分後でも 1km 以上離れていれば別の食事（はしご）
        let groups = Matcher.groupMeals([photo("a", minutes: 0), photo("b", minutes: 10, lat: 35.7000, lon: 139.7000)])
        XCTAssertEqual(groups.count, 2)
    }

    func testCluePhotosAreNonFoodNearTheMeal() {
        let meal = [photo("food", minutes: 0)]
        let all = meal + [
            photo("sign", minutes: -5, food: 0.0),
            photo("menu", minutes: 3, food: 0.1),
            photo("later", minutes: 120, food: 0.0),
            photo("far", minutes: 2, lat: 35.75, lon: 139.75, food: 0.0),
        ]
        let clues = Matcher.cluePhotos(for: meal, among: all).map(\.id)
        XCTAssertEqual(Set(clues), ["sign", "menu"])
    }

    // MARK: 文字の比べ方

    func testNormalizeIgnoresWidthCaseAndSpaces() {
        XCTAssertEqual(Matcher.normalize("ＡＢＣ　Cafe"), Matcher.normalize("abc cafe"))
    }

    func testSignMatchesShopNameWithoutBranch() {
        XCTAssertEqual(Matcher.textMatch(name: "麺屋 武蔵 新宿店", lines: ["営業中", "麺屋武蔵"]), 1)
    }

    func testUnrelatedTextDoesNotMatch() {
        XCTAssertLessThan(Matcher.textMatch(name: "スターバックス", lines: ["らーめん", "替玉 100円"]), 0.3)
    }

    func testSearchableLinesSkipPricesAndNumbers() {
        let lines = Matcher.searchableLines(["醤油らーめん 900円", "2026/11/21", "麺屋武蔵", "OPEN", "合計 1,800"])
        XCTAssertEqual(lines, ["麺屋武蔵", "OPEN"])
    }

    // MARK: お店の点数

    func testNameOnSignBeatsCloserShop() {
        let near = PlaceCandidate(name: "カフェ ドトール", address: "", category: "MKPOICategoryCafe",
                                  latitude: 0, longitude: 0, distance: 10)
        let named = PlaceCandidate(name: "麺屋 武蔵", address: "", category: "MKPOICategoryRestaurant",
                                   latitude: 0, longitude: 0, distance: 60)
        let ranked = Matcher.rank([near, named], lines: ["麺屋武蔵"], dishLabel: "ramen")
        XCTAssertEqual(ranked.first?.name, "麺屋 武蔵")
    }

    func testOnDeviceIsUnsureWhenTwoShopsTie() {
        let a = PlaceCandidate(name: "A", address: "", category: "", latitude: 0, longitude: 0, distance: 20, score: 0.5)
        let b = PlaceCandidate(name: "B", address: "", category: "", latitude: 0, longitude: 0, distance: 22, score: 0.49)
        let (_, confidence) = Matcher.decideOnDevice([a, b])
        XCTAssertLessThan(confidence, Matcher.sureLine)
    }

    func testAIMinusOneMeansNoShop() {
        let a = PlaceCandidate(name: "A", address: "", category: "", latitude: 0, longitude: 0, distance: 20, score: 0.9)
        let result = Matcher.decide(ranked: [a], aiIndex: -1, aiConfidence: 0.2)
        XCTAssertNil(result.pick)
    }

    func testAIPickIsUsed() {
        let a = PlaceCandidate(name: "A", address: "", category: "", latitude: 0, longitude: 0, distance: 20, score: 0.9)
        let b = PlaceCandidate(name: "B", address: "", category: "", latitude: 0, longitude: 0, distance: 90, score: 0.3)
        let result = Matcher.decide(ranked: [a, b], aiIndex: 1, aiConfidence: 0.8)
        XCTAssertEqual(result.pick?.name, "B")
        XCTAssertEqual(result.confidence, 0.8, accuracy: 0.001)
    }

    func testMergeKeepsCloserAndVisited() {
        let map = PlaceCandidate(name: "麺屋 武蔵", address: "新宿", category: "MKPOICategoryRestaurant",
                                 latitude: 1, longitude: 1, distance: 80)
        let past = PlaceCandidate(name: "麺屋　武蔵", address: "", category: "", latitude: 2, longitude: 2,
                                  distance: 40, visited: true)
        let merged = PlaceFinder.merge([[map], [past]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].distance, 40)
        XCTAssertTrue(merged[0].visited)
        XCTAssertEqual(merged[0].address, "新宿")
    }

    func testDistance() {
        // 新宿駅 → 東京駅 はおよそ 6.2km
        let d = Matcher.distance(35.6896, 139.7006, 35.6812, 139.7671)
        XCTAssertEqual(d, 6_100, accuracy: 300)
    }

    func testSpreadPicksEvenly() {
        XCTAssertEqual(Scanner.spread([1, 2, 3, 4, 5, 6], count: 3), [1, 3, 5])
        XCTAssertEqual(Scanner.spread([1, 2], count: 3), [1, 2])
    }
}

final class ClaudeParseTests: XCTestCase {
    func testParsesVerdictAndCost() throws {
        let json = """
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\\"is_meal\\":true,\\"eaten_out\\":true,\\"place_index\\":2,\\"place_confidence\\":0.85,\\"genre\\":\\"ラーメン\\",\\"dishes\\":[\\"味玉醤油ラーメン\\"],\\"summary\\":\\"澄んだ醤油ラーメン\\"}"}],
         "stop_reason":"end_turn","usage":{"input_tokens":1000000,"output_tokens":0}}
        """
        let (verdict, usd) = try ClaudeVision.parse(Data(json.utf8))
        XCTAssertEqual(verdict.place_index, 2)
        XCTAssertEqual(verdict.dishes, ["味玉醤油ラーメン"])
        XCTAssertEqual(usd, 2, accuracy: 0.001)   // ふだんのモデル（Sonnet）の入力 100万トークン = $2
    }

    func testRefusalThrows() {
        let json = #"{"content":[],"stop_reason":"refusal","usage":{"input_tokens":10,"output_tokens":0}}"#
        XCTAssertThrowsError(try ClaudeVision.parse(Data(json.utf8)))
    }

    func testPromptListsCandidatesWithIndex() {
        let c = PlaceCandidate(name: "麺屋 武蔵", address: "新宿区", category: "MKPOICategoryRestaurant",
                               latitude: 0, longitude: 0, distance: 42.4, visited: true)
        let text = ClaudeVision.prompt(date: Date(), area: "新宿", candidates: [c], lines: ["麺屋武蔵"], foodCount: 2, clueCount: 1)
        XCTAssertTrue(text.contains("0. 麺屋 武蔵（42m・前にも行ったお店）新宿区"))
        XCTAssertTrue(text.contains("麺屋武蔵"))
    }
}
