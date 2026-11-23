import XCTest
@testable import Gohan

/// 2026-11-23 に足した決め方のテスト
final class NewRulesTests: XCTestCase {
    private func photo(_ id: String, minutes: Double, lat: Double? = 35.69, lon: Double? = 139.70, label: String = "ramen") -> SeenPhoto {
        SeenPhoto(id: id, date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), latitude: lat, longitude: lon,
                  accuracy: 20, food: 0.9, label: label)
    }

    // 便19: カフェ → ごはん は別の食事
    func testCafeThenDinnerSplits() {
        let groups = Matcher.groupMeals([photo("latte", minutes: 0, label: "coffee"), photo("ramen", minutes: 30, label: "ramen")])
        XCTAssertEqual(groups.count, 2)
    }

    func testDessertRightAfterMealStaysTogether() {
        let groups = Matcher.groupMeals([photo("pasta", minutes: 0, label: "pasta"), photo("cake", minutes: 10, label: "cake")])
        XCTAssertEqual(groups.count, 1)
    }

    // 便16: 場所の無い写真は前後の写真から借りる
    func testBorrowsLocationFromNearbyPhoto() {
        let noPlace = photo("food", minutes: 10, lat: nil, lon: nil)
        let sign = photo("sign", minutes: 5)
        let filled = Matcher.fillLocations([noPlace], among: [noPlace, sign])
        XCTAssertEqual(filled.first?.latitude, 35.69)
    }

    func testDoesNotBorrowFromFarInTime() {
        let noPlace = photo("food", minutes: 0, lat: nil, lon: nil)
        let old = photo("old", minutes: -120)
        XCTAssertNil(Matcher.fillLocations([noPlace], among: [noPlace, old]).first?.latitude)
    }

    // 便18: レシートの上の店名
    func testReceiptName() {
        let lines = ["麺屋 こもれび", "新宿区新宿3-1-1", "TEL 03-1234-5678", "領収書", "味玉らーめん 1,000円", "合計 1,000円"]
        XCTAssertEqual(Matcher.receiptNames(lines).first, "麺屋 こもれび")
        XCTAssertTrue(Matcher.receiptNames(["営業中", "OPEN"]).isEmpty)
    }

    // 便27: 料理名のゆれ
    func testDishKeyFoldsKana() {
        XCTAssertEqual(Matcher.dishKey("らーめん"), Matcher.dishKey("ラーメン"))
        XCTAssertEqual(Matcher.dishKey("ｶﾚｰ"), Matcher.dishKey("カレー"))
    }

    func testCanonicalUsesMostCommonSpelling() {
        let book = Matcher.dishBook([["味玉ラーメン"], ["味玉ラーメン"], ["味玉らーめん"]])
        XCTAssertEqual(Matcher.canonicalDishes(["味玉らーめん"], book: book), ["味玉ラーメン"])
    }

    // 便51: 直したら覚える
    func testCorrectionsMoveRightShopUp() {
        let a = PlaceCandidate(name: "ちがう店", address: "", category: "", latitude: 0, longitude: 0, distance: 10, score: 0.8)
        let b = PlaceCandidate(name: "正しい店", address: "", category: "", latitude: 0, longitude: 0, distance: 40, score: 0.5)
        let out = Matcher.applyCorrections([a, b], right: [Matcher.normalize("正しい店")], wrong: [Matcher.normalize("ちがう店")])
        XCTAssertEqual(out.first?.name, "正しい店")
    }

    // 便11: 前に行ったお店は AI に聞かない
    func testKnownPlaceNeedsMargin() {
        var top = PlaceCandidate(name: "A", address: "", category: "", latitude: 0, longitude: 0, distance: 20, score: 0.9, visited: true)
        let second = PlaceCandidate(name: "B", address: "", category: "", latitude: 0, longitude: 0, distance: 30, score: 0.5)
        XCTAssertNotNil(Matcher.knownPlace([top, second]))
        top.visited = false
        XCTAssertNil(Matcher.knownPlace([top, second]))
    }

    // 便20: 旅行のまとまり
    func testTripsGroupFarMeals() {
        let home = (latitude: 35.69, longitude: 139.70)
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let meals = [
            Matcher.TripInput(id: UUID(), date: base, latitude: 34.70, longitude: 135.50, region: "大阪府"),
            Matcher.TripInput(id: UUID(), date: base.addingTimeInterval(day), latitude: 34.69, longitude: 135.51, region: "大阪府"),
            Matcher.TripInput(id: UUID(), date: base.addingTimeInterval(10 * day), latitude: 35.69, longitude: 139.70, region: "東京都"),
        ]
        let trips = Matcher.trips(meals, home: home)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.region, "大阪府")
        XCTAssertEqual(trips.first?.mealIDs.count, 2)
    }

    // 前の版で保存した写真の覚え・お店の候補も読める
    func testOldSeenPhotoDecodes() throws {
        let json = #"{"id":"x","date":0,"food":0.5,"label":"ramen","used":true}"#
        let p = try JSONDecoder().decode(SeenPhoto.self, from: Data(json.utf8))
        XCTAssertFalse(p.isVideo)
        XCTAssertTrue(p.used)
    }

    func testOldCandidateDecodes() throws {
        let json = #"[{"name":"A","address":"","category":"","latitude":1,"longitude":2,"distance":3,"score":0.5,"visited":false}]"#
        let list = try JSONDecoder().decode([PlaceCandidate].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.phone, "")
    }

    // 便13: まとめ処理の答え（並びは custom_id で引く）
    func testBatchResultsParse() {
        let id = UUID()
        let text = #"{\"is_meal\":true,\"eaten_out\":true,\"place_index\":0,\"place_confidence\":0.9,\"genre\":\"カフェ\",\"dishes\":[\"ラテ\"],\"summary\":\"ラテ\",\"kind\":\"drink\",\"reason\":\"看板\"}"#
        let line = #"{"custom_id":"\#(id.uuidString)","result":{"type":"succeeded","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","usage":{"input_tokens":1000000,"output_tokens":0}}}}"#
        let other = #"{"custom_id":"not-a-uuid","result":{"type":"errored"}}"#
        let results = BatchQueue.parseResults(Data((line + "\n" + other).utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.0, id)
        if case .success(let v) = results.first?.1 { XCTAssertEqual(v.kind, "drink") } else { XCTFail("読めなかった") }
    }

    // 便1: 鍵の受け渡し
    func testKeyHandoffNeedsRightCode() {
        let payload = KeyHandoff.Payload(key: "sk-ant-test", relayURL: nil, relayToken: nil, cap: 5, showCost: false)
        let sealed = KeyHandoff.seal(payload, code: "123456")
        XCTAssertNotNil(sealed)
        XCTAssertEqual(KeyHandoff.open(sealed ?? "", code: "123456")?.key, "sk-ant-test")
        XCTAssertNil(KeyHandoff.open(sealed ?? "", code: "654321"))
    }

    // 便43: Google マップのリンクから店名と位置
    func testGooglePlaceLink() {
        let url = URL(string: "https://www.google.com/maps/place/%E9%BA%BA%E3%82%84+%E3%81%93%E3%82%82%E3%82%8C%E3%81%B3/@35.6909,139.7003,17z/data=x")!
        let guess = WishReader.googlePlace(url)
        XCTAssertEqual(guess?.query, "麺や こもれび")
        XCTAssertEqual(guess?.latitude ?? 0, 35.6909, accuracy: 0.0001)
    }

    func testMealVerdictWithoutNewFields() throws {
        let json = #"{"is_meal":true,"eaten_out":false,"place_index":-1,"place_confidence":0.2,"genre":"和食","dishes":[],"summary":""}"#
        let v = try JSONDecoder().decode(MealVerdict.self, from: Data(json.utf8))
        XCTAssertEqual(v.kind, "meal")
    }
}
