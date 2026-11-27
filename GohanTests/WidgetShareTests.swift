import XCTest
@testable import Gohan

/// 2026-11-28 ホーム画面の小窓・共有ボタン（大18・大19）
final class WidgetShareTests: XCTestCase {
    func testMemoryPicksClosestToOneYearAgo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let target = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let a = UUID(), b = UUID(), c = UUID()
        let meals = [(id: a, date: target.addingTimeInterval(2 * 86_400)), (id: b, date: target.addingTimeInterval(-3_600)),
                     (id: c, date: target.addingTimeInterval(10 * 86_400))]
        XCTAssertEqual(WidgetFeed.memory(meals, now: now), b)
        XCTAssertNil(WidgetFeed.memory([(id: c, date: target.addingTimeInterval(10 * 86_400))], now: now))
    }

    func testWantPicksTheLongestAgo() {
        let places: [(key: String, last: Date?)] = [("new", Date()), ("old", Date(timeIntervalSince1970: 0)), ("never", nil)]
        XCTAssertEqual(WidgetFeed.want(places), "never")
        XCTAssertNil(WidgetFeed.want([]))
    }

    func testLinks() {
        XCTAssertEqual(ShareInbox.mealURL("ABC")?.absoluteString, "gohan://meal/ABC")
        let url = ShareInbox.placeURL("麺屋|35.1|139.2")
        XCTAssertEqual(url?.scheme, "gohan")
        XCTAssertEqual(url?.host, "place")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "麺屋|35.1|139.2")
    }

    func testFeedFileRoundTrip() throws {
        let feed = WidgetFeedFile(made: Date(timeIntervalSince1970: 1_800_000_000),
                                  memory: .init(title: "醤油ラーメン", date: Date(timeIntervalSince1970: 1_768_000_000), mealID: "x", image: nil),
                                  want: .init(name: "麺屋はるか", detail: "", key: "k"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(WidgetFeedFile.self, from: encoder.encode(feed)), feed)
    }
}
