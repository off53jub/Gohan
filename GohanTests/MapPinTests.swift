import XCTest
@testable import Gohan

/// 2026-11-27: 地図の出入りを軽くする（見えている所のピンだけ・上限つき）
final class MapPinTests: XCTestCase {
    private func pin(_ id: String, lat: Double, lon: Double, want: Bool = false, day: Double = 0) -> MapPin {
        MapPin(id: id, name: id, latitude: lat, longitude: lon, photo: nil, want: want,
               latest: Date(timeIntervalSince1970: day * 86_400))
    }

    func testOutsideTheViewIsLeftOff() {
        let pins = [pin("新宿", lat: 35.69, lon: 139.70), pin("大阪", lat: 34.70, lon: 135.50)]
        let shown = MapPin.visible(pins, center: (35.69, 139.70), span: (0.1, 0.1))
        XCTAssertEqual(shown.map(\.id), ["新宿"])
    }

    func testNoCameraYetShowsAll() {
        let pins = [pin("a", lat: 35, lon: 139), pin("b", lat: 34, lon: 135)]
        XCTAssertEqual(MapPin.visible(pins, center: nil, span: nil).count, 2)
    }

    func testCapKeepsWantAgainThenNewest() {
        let pins = [pin("old", lat: 0, lon: 0, day: 1), pin("new", lat: 0, lon: 0, day: 9), pin("want", lat: 0, lon: 0, want: true, day: 0)]
        let shown = MapPin.visible(pins, center: nil, span: nil, limit: 2)
        XCTAssertEqual(shown.map(\.id), ["want", "new"])
    }
}
