import XCTest
@testable import Gohan

/// 2026-11-26 Yahoo!・OpenStreetMap・Foursquare・Google のクチコミ
final class MorePlaceSourcesTests: XCTestCase {
    func testParsesYahooLocalSearch() {
        let json = """
        {"ResultInfo":{"Count":1,"Status":200},"Feature":[{"Id":"1","Name":"麺屋こもれび",
          "Geometry":{"Type":"point","Coordinates":"139.7001,35.6901"},
          "Property":{"Address":"東京都新宿区西新宿1-1","Tel1":"03-0000-0000",
                      "Genre":[{"Code":"0101001","Name":"ラーメン"}],"Building":{"Id":"b","Name":"新宿ビル"}}}]}
        """
        let list = YahooLocal.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.latitude, 35.6901)
        XCTAssertEqual(list.first?.longitude, 139.7001)
        XCTAssertEqual(list.first?.category, "yahoo:ラーメン")
        XCTAssertEqual(list.first?.address, "東京都新宿区西新宿1-1 新宿ビル")
        XCTAssertEqual(Genre.from(category: list.first?.category ?? ""), "ラーメン")
    }

    func testParsesOpenStreetMap() {
        let json = """
        {"elements":[{"type":"node","lat":35.6902,"lon":139.7002,"tags":{"name":"Komorebi","name:ja":"こもれび","amenity":"restaurant","cuisine":"ramen"}},
                     {"type":"way","center":{"lat":35.6903,"lon":139.7003},"tags":{"name":"Cafe X","amenity":"cafe"}},
                     {"type":"node","lat":35.69,"lon":139.70,"tags":{"amenity":"restaurant"}}]}
        """
        let list = OSMPlaces.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(list.map(\.name), ["こもれび", "Cafe X"])
        XCTAssertEqual(Genre.from(category: list[0].category), "ラーメン")
        XCTAssertEqual(Genre.from(category: list[1].category), "カフェ")
    }

    func testParsesFoursquare() {
        let json = """
        {"results":[{"fsq_place_id":"a","name":"Sushi Taro","latitude":35.6905,"longitude":139.7005,"distance":60,
          "categories":[{"name":"Sushi Restaurant"}],"location":{"formatted_address":"新宿"}}]}
        """
        let list = FoursquarePlaces.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(list.first?.name, "Sushi Taro")
        XCTAssertEqual(Genre.from(category: list.first?.category ?? ""), "寿司")
    }

    func testReviewKeywordsDropCommonWords() {
        XCTAssertEqual(ReviewMatch.keywords(dishes: ["鴨ねぎ醤油ラーメン", "味玉"]), ["鴨ねぎ"])
        XCTAssertEqual(ReviewMatch.keywords(dishes: ["醤油ラーメン"]), [])
    }

    func testReviewTextsComeFromTheMatchingShop() {
        let json = """
        {"places":[{"displayName":{"text":"麺屋こもれび"},"location":{"latitude":35.6901,"longitude":139.7001},
          "reviews":[{"text":{"text":"鴨ねぎが最高"}}],"editorialSummary":{"text":"鴨のラーメン"}},
          {"displayName":{"text":"別の店"},"location":{"latitude":35.69,"longitude":139.70},"reviews":[{"text":{"text":"x"}}]}]}
        """
        let texts = GooglePlaces.reviewTexts(Data(json.utf8), name: "麺屋こもれび", latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(texts, ["鴨ねぎが最高", "鴨のラーメン"])
    }
}
