import XCTest
@testable import Gohan

/// 2026-11-28 Google のタイムライン（大3）
final class GoogleTimelineTests: XCTestCase {
    private let sample = #"""
    [{"endTime":"2026-05-11T11:19:06.861+09:00","startTime":"2026-05-11T09:34:29.680+09:00",
      "visit":{"topCandidate":{"placeLocation":"geo:35.452706,139.391113"}}},
     {"endTime":"2026-05-11T02:00:00.000Z","startTime":"2026-05-11T00:00:00.000Z",
      "timelinePath":[{"point":"geo:35.497878,139.407482","durationMinutesOffsetFromStartTime":"29"}]},
     {"endTime":"2026-05-11T09:34:29.680+09:00","startTime":"2026-05-11T09:28:33.086+09:00",
      "activity":{"start":"geo:35.5,139.4","end":"geo:35.45,139.39"}}]
    """#

    func testParseVisitsAndPath() {
        let spots = GoogleTimeline.parse(Data(sample.utf8))
        XCTAssertEqual(spots.count, 2)
        let stay = spots.first { $0.stay }!
        XCTAssertEqual(stay.latitude, 35.452706, accuracy: 1e-6)
        let point = spots.first { !$0.stay }!
        XCTAssertEqual(point.start, GoogleTimeline.date("2026-05-11T00:29:00Z"))
    }

    func testStayAt() {
        let spots = GoogleTimeline.parse(Data(sample.utf8))
        XCTAssertNotNil(GoogleTimeline.stay(at: GoogleTimeline.date("2026-05-11T10:00:00+09:00")!, in: spots))
        XCTAssertNil(GoogleTimeline.stay(at: GoogleTimeline.date("2026-05-11T12:00:00+09:00")!, in: spots))
    }

    func testWrappedFormatAndJunk() {
        XCTAssertEqual(GoogleTimeline.parse(Data(("{\"semanticSegments\":" + sample + "}").utf8)).count, 2)
        XCTAssertTrue(GoogleTimeline.parse(Data("nope".utf8)).isEmpty)
        XCTAssertNil(GoogleTimeline.geo("35,139"))
    }
}
