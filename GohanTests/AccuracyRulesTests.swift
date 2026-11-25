import XCTest
@testable import Gohan

/// 2026-11-25 精度の施策（ういちゃんにも当てはまるもの）
final class AccuracyRulesTests: XCTestCase {
    private func photo(_ id: String, minutes: Double, lat: Double? = 35.6900, lon: Double? = 139.7000,
                       food: Double = 0.9, noCamera: Bool = false) -> SeenPhoto {
        SeenPhoto(id: id, date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), latitude: lat, longitude: lon,
                  accuracy: 20, food: food, label: "ramen", noCamera: noCamera)
    }

    // 同じ場所なら 90 分あいても 1 回の食事（飲み会・コース）
    func testLongMealAtSameSpotStaysTogether() {
        let groups = Matcher.groupMeals([photo("start", minutes: 0), photo("dessert", minutes: 70)])
        XCTAssertEqual(groups.count, 1)
    }

    // 位置が分からなければ、今までどおり 40 分で区切る
    func testLongGapWithoutLocationStillSplits() {
        let groups = Matcher.groupMeals([photo("a", minutes: 0, lat: nil, lon: nil), photo("b", minutes: 70, lat: nil, lon: nil)])
        XCTAssertEqual(groups.count, 2)
    }

    // 少し離れた場所（150m）なら、40 分を超えたら別の食事（はしご）
    func testLongGapAtNearbyButDifferentSpotSplits() {
        let groups = Matcher.groupMeals([photo("a", minutes: 0), photo("b", minutes: 70, lat: 35.6913, lon: 139.7000)])
        XCTAssertEqual(groups.count, 2)
    }

    func testCompanionPhotosAreTakenDuringTheMealAtTheSamePlace() {
        let meal = [photo("food1", minutes: 0), photo("food2", minutes: 30)]
        let all = meal + [
            photo("friends", minutes: 10, food: 0.0),
            photo("inside", minutes: 32, food: 0.1),
            photo("before", minutes: -30, food: 0.0),
            photo("far", minutes: 15, lat: 35.70, lon: 139.71, food: 0.0),
            photo("saved", minutes: 12, food: 0.0, noCamera: true),
        ]
        XCTAssertEqual(Matcher.companionPhotos(for: meal, among: all).map(\.id), ["friends", "inside"])
    }

    // 料理の名前とジャンルをそろえる
    func testGenreFollowsDishName() {
        XCTAssertEqual(Matcher.consistentGenre("丼", dishes: ["味玉醤油ラーメン"], shop: nil, shopConfidence: 0), "ラーメン")
        // 同じ系統なら変えない（つけ麺はラーメンの仲間）
        XCTAssertEqual(Matcher.consistentGenre("つけ麺", dishes: ["濃厚つけ麺"], shop: nil, shopConfidence: 0), "つけ麺")
        // 甘いもの・飲み物は変えない
        XCTAssertEqual(Matcher.consistentGenre("カフェ", dishes: ["ラーメン味のアイス"], shop: nil, shopConfidence: 0), "カフェ")
    }

    // 1 つの料理しか出さないお店に自信があれば、お店に合わせる
    func testGenreFollowsSinglePurposeShop() {
        let shop = PlaceCandidate(name: "麺屋こもれび", address: "", category: "", latitude: 35.69, longitude: 139.70, distance: 10)
        XCTAssertEqual(Matcher.consistentGenre("丼", dishes: [], shop: shop, shopConfidence: 0.9), "ラーメン")
        // 自信が低ければ変えない
        XCTAssertEqual(Matcher.consistentGenre("丼", dishes: [], shop: shop, shopConfidence: 0.6), "丼")
        // スイーツはどのお店でも食べるので変えない
        XCTAssertEqual(Matcher.consistentGenre("スイーツ", dishes: [], shop: shop, shopConfidence: 0.9), "スイーツ")
    }
}
