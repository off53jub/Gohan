import XCTest
@testable import Gohan

/// 2026-11-27: 当たり具合の記録から直したこと
final class ReviewAndCrowdTests: XCTestCase {
    private func shop(_ name: String, distance: Double = 30, category: String = "MKPOICategoryRestaurant", score: Double = 0.5) -> PlaceCandidate {
        PlaceCandidate(name: name, address: "", category: category, latitude: 0, longitude: 0, distance: distance, score: score)
    }

    // A: お店の多い所では埋めない
    func testCrowdedWhenAnotherRamenShopIsNear() {
        let nearby = [shop("春日亭 西新宿店"), shop("中華そば 流川"), shop("カフェ ドトール")]
        XCTAssertTrue(RetroFix.crowded(nearby, shop: "春日亭 西新宿店", genre: "ラーメン", shopGenre: "ラーメン"))
    }

    func testNotCrowdedWhenOnlyOtherKindsAreNear() {
        let nearby = [shop("春日亭 西新宿店"), shop("カフェ ドトール", category: "MKPOICategoryCafe")]
        XCTAssertFalse(RetroFix.crowded(nearby, shop: "春日亭 西新宿店", genre: "ラーメン", shopGenre: "ラーメン"))
    }

    func testShopOfUnknownKindCountsAsCrowded() {
        // 「一蘭」は名前から種類が分からない。同じジャンルかもしれないので埋めない
        XCTAssertTrue(RetroFix.crowded([shop("春日亭 西新宿店"), shop("一蘭 西新宿店")], shop: "春日亭 西新宿店", genre: "ラーメン", shopGenre: nil))
    }

    func testUnknownSurroundingsCountAsCrowded() {
        XCTAssertTrue(RetroFix.crowded([], shop: "春日亭", genre: "ラーメン", shopGenre: nil))
    }

    // B: 種類の合わない候補を強く下げる・コンビニを外す
    func testRamenBeatsCloserCafe() {
        let cafe = shop("カフェイタリアン ミエーレ", distance: 5, category: "MKPOICategoryCafe", score: 0.6)
        let ramen = shop("らーめん 鴨to葱", distance: 60, score: 0.4)
        let out = Matcher.applyGenre([cafe, ramen], photoGenre: "ラーメン")
        XCTAssertEqual(out.first?.name, "らーめん 鴨to葱")
    }

    func testSweetsStillMoveGently() {
        XCTAssertEqual(Matcher.genreShift(fit: -1, strict: false), -0.08, accuracy: 0.001)
        XCTAssertEqual(Matcher.genreShift(fit: -1, strict: true), -0.25, accuracy: 0.001)
        XCTAssertEqual(Matcher.genreShift(fit: 0, strict: true), 0)
    }

    func testConvenienceStoresAreDropped() {
        XCTAssertTrue(Matcher.isConvenienceStore("ファミリーマート 三郷みなみ店"))
        XCTAssertTrue(Matcher.isConvenienceStore("セブン-イレブン 金沢高岡町店"))
        XCTAssertTrue(Matcher.isConvenienceStore("LAWSON 新宿"))
        XCTAssertFalse(Matcher.isConvenienceStore("バーミヤン 三郷戸ケ崎店"))
        let ranked = Matcher.rank([shop("ファミリーマート 三郷みなみ店", distance: 5), shop("バーミヤン 三郷戸ケ崎店", distance: 80)],
                                  lines: [], dishLabel: "")
        XCTAssertEqual(ranked.map(\.name), ["バーミヤン 三郷戸ケ崎店"])
    }

    // 「たぶん」を見る順
    func testReviewOrderPutsGuessedShopsFirst() {
        XCTAssertEqual(ReviewOrder.tier(hasPlace: true, hasLocation: false), 0)
        XCTAssertEqual(ReviewOrder.tier(hasPlace: false, hasLocation: true), 1)
        XCTAssertEqual(ReviewOrder.tier(hasPlace: false, hasLocation: false), 2)
        // (名前, 段)。新しい順で来たものを、段の順に。同じ段の中は元の順
        let items = [("分からない1", 2), ("当てた1", 0), ("場所だけ", 1), ("分からない2", 2), ("当てた2", 0)]
        XCTAssertEqual(ReviewOrder.sorted(items) { $0.1 }.map(\.0), ["当てた1", "当てた2", "場所だけ", "分からない1", "分からない2"])
    }
}
