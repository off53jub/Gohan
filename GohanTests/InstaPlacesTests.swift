import XCTest
@testable import Gohan

/// 2026-11-28 インスタの投稿の店名で、お店の無い食事を埋める（大1）
final class InstaPlacesTests: XCTestCase {
    private func shop(_ name: String, address: String = "", category: String = "MKPOICategoryRestaurant") -> PlaceCandidate {
        PlaceCandidate(name: name, address: address, category: category, latitude: 35.69, longitude: 139.76, distance: 0)
    }

    func testBestNamedPicksTheMatchingShop() {
        let found = [shop("神保町駅", category: "MKPOICategoryPublicTransport"), shop("黒須", address: "東京都千代田区神田神保町"), shop("ラーメン二郎")]
        XCTAssertEqual(PCImport.bestNamed(found, name: "黒須", area: "神保町")?.name, "黒須")
    }

    func testBestNamedRejectsStationsAndWeakNames() {
        XCTAssertNil(PCImport.bestNamed([shop("神保町駅", category: "MKPOICategoryPublicTransport")], name: "神保町", area: nil))
        XCTAssertNil(PCImport.bestNamed([shop("ラーメン二郎")], name: "黒須", area: nil))
    }

    func testBestNamedPrefersTheAreaWhenNamesTie() {
        let found = [shop("山岡家", address: "千葉県君津市"), shop("山岡家", address: "東京都新宿区歌舞伎町")]
        XCTAssertEqual(PCImport.bestNamed(found, name: "山岡家", area: "新宿")?.address, "東京都新宿区歌舞伎町")
    }

    func testOldImportFilesStillRead() throws {
        let json = #"{"name":"黒須","latitude":null,"longitude":null,"confidence":0.85,"reason":"r"}"#
        let place = try JSONDecoder().decode(ImportPlace.self, from: Data(json.utf8))
        XCTAssertNil(place.area)
        let withArea = try JSONDecoder().decode(ImportPlace.self, from: Data(#"{"name":"黒須","confidence":0.5,"reason":"r","area":"神保町"}"#.utf8))
        XCTAssertEqual(withArea.area, "神保町")
    }
}
