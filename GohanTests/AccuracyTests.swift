import XCTest
@testable import Gohan

/// 精度1〜4（2026-11-24）: 訪問の記録・営業時間・お店の写真・試験
final class AccuracyTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // 1. 訪問の記録
    func testVisitMatchPicksShortestOverlap() {
        let lunch = Visit(arrival: date(2026, 11, 20, 12, 0), departure: date(2026, 11, 20, 12, 50), latitude: 35.69, longitude: 139.70, accuracy: 40)
        let office = Visit(arrival: date(2026, 11, 20, 9, 0), departure: date(2026, 11, 20, 18, 0), latitude: 35.68, longitude: 139.76, accuracy: 30)
        let found = VisitLog.match([office, lunch], from: date(2026, 11, 20, 12, 15), to: date(2026, 11, 20, 12, 30))
        XCTAssertEqual(found, lunch)
        XCTAssertEqual(found?.minutes, 50)
        XCTAssertNil(VisitLog.match([lunch], from: date(2026, 11, 20, 14, 0), to: date(2026, 11, 20, 14, 10)))
    }

    func testVisitAddReplacesSameArrivalAndDropsOld() {
        let now = date(2026, 11, 24, 12, 0)
        let arriving = Visit(arrival: date(2026, 11, 24, 11, 0), departure: nil, latitude: 35, longitude: 139, accuracy: 50)
        let left = Visit(arrival: date(2026, 11, 24, 11, 0), departure: date(2026, 11, 24, 11, 40), latitude: 35, longitude: 139, accuracy: 50)
        let ancient = Visit(arrival: date(2026, 5, 1, 12, 0), departure: date(2026, 5, 1, 13, 0), latitude: 35, longitude: 139, accuracy: 50)
        let list = VisitLog.add(left, to: [ancient, arriving], now: now)
        XCTAssertEqual(list, [left])
    }

    func testUseVisitOnlyWhenPhotoIsVague() {
        let visit = Visit(arrival: nil, departure: nil, latitude: 35.6900, longitude: 139.7000, accuracy: 30)
        XCTAssertTrue(Matcher.useVisit(visit, spot: nil, accuracy: nil))
        XCTAssertFalse(Matcher.useVisit(visit, spot: (35.6901, 139.7001), accuracy: 10))
        XCTAssertTrue(Matcher.useVisit(visit, spot: (35.6905, 139.7004), accuracy: 120))
        XCTAssertFalse(Matcher.useVisit(visit, spot: (35.7200, 139.7000), accuracy: 120))
    }

    // 2. 営業時間
    func testHotPepperHours() {
        let open = "月～金、祝前日: 11:30～15:00 （料理L.O. 14:30）17:00～翌2:00 （料理L.O. 1:00）"
        XCTAssertEqual(OpenHours.isOpen(hours: open, closed: "", at: date(2026, 11, 24, 12, 30), calendar: tokyo), true)
        XCTAssertEqual(OpenHours.isOpen(hours: open, closed: "", at: date(2026, 11, 24, 16, 10), calendar: tokyo), false)
        XCTAssertEqual(OpenHours.isOpen(hours: open, closed: "", at: date(2026, 11, 24, 1, 30), calendar: tokyo), true)
        XCTAssertEqual(OpenHours.isOpen(hours: "18:00～26:00", closed: "", at: date(2026, 11, 24, 1, 0), calendar: tokyo), true)
        XCTAssertNil(OpenHours.isOpen(hours: "", closed: "", at: date(2026, 11, 24, 12, 0), calendar: tokyo))
        XCTAssertNil(OpenHours.isOpen(hours: "要問合せ", closed: "", at: date(2026, 11, 24, 12, 0), calendar: tokyo))
    }

    func testClosedDays() {
        // 2026-11-24 は火曜日
        let tuesday = date(2026, 11, 24, 12, 0)
        XCTAssertTrue(OpenHours.closedOn("火曜日", at: tuesday, calendar: tokyo))
        XCTAssertTrue(OpenHours.closedOn("月・火", at: tuesday, calendar: tokyo))
        XCTAssertFalse(OpenHours.closedOn("日・祝", at: tuesday, calendar: tokyo))
        XCTAssertFalse(OpenHours.closedOn("第2・第4火曜日", at: tuesday, calendar: tokyo))
        XCTAssertFalse(OpenHours.closedOn("不定休", at: tuesday, calendar: tokyo))
        XCTAssertFalse(OpenHours.closedOn("無休", at: tuesday, calendar: tokyo))
        XCTAssertEqual(OpenHours.isOpen(hours: "11:00～22:00", closed: "火", at: tuesday, calendar: tokyo), false)
    }

    func testGoogleHours() {
        // 火曜（day 2）の 11:00〜14:00 と、金曜の夜から土曜の朝まで
        let periods: [[String: Any]] = [
            ["open": ["day": 2, "hour": 11, "minute": 0], "close": ["day": 2, "hour": 14, "minute": 0]],
            ["open": ["day": 5, "hour": 22, "minute": 0], "close": ["day": 6, "hour": 4, "minute": 0]],
        ]
        let text = OpenHours.googleText(periods)
        XCTAssertTrue(text.hasPrefix("G|"))
        XCTAssertEqual(OpenHours.isOpen(hours: text, closed: "", at: date(2026, 11, 24, 12, 0), calendar: tokyo), true)
        XCTAssertEqual(OpenHours.isOpen(hours: text, closed: "", at: date(2026, 11, 24, 19, 0), calendar: tokyo), false)
        XCTAssertEqual(OpenHours.isOpen(hours: text, closed: "", at: date(2026, 11, 28, 2, 0), calendar: tokyo), true)
        let always = OpenHours.googleText([["open": ["day": 0, "hour": 0, "minute": 0]]])
        XCTAssertEqual(OpenHours.isOpen(hours: always, closed: "", at: date(2026, 11, 24, 3, 0), calendar: tokyo), true)
    }

    func testClosedShopsGoDown() {
        var night = PlaceCandidate(name: "夜だけの店", address: "", category: "", latitude: 35, longitude: 139, distance: 10)
        night.score = 0.8
        night.hours = "18:00～23:00"
        var lunch = PlaceCandidate(name: "昼の店", address: "", category: "", latitude: 35, longitude: 139, distance: 30)
        lunch.score = 0.6
        lunch.hours = "11:00～15:00"
        let ranked = Matcher.applyHours([night, lunch], at: date(2026, 11, 24, 12, 30), calendar: tokyo)
        XCTAssertEqual(ranked.first?.name, "昼の店")
        XCTAssertTrue(ranked.last?.closedThen ?? false)
        let prompt = ClaudeVision.prompt(date: Date(), area: "", candidates: ranked, lines: [], foodCount: 1, clueCount: 0, stay: 45)
        XCTAssertTrue(prompt.contains("営業時間外"))
        XCTAssertTrue(prompt.contains("約45分"))
    }

    func testHotPepperParseKeepsHoursAndPhoto() {
        let json = #"{"results":{"shop":[{"name":"麺屋 こもれび","lat":35.69,"lng":139.70,"address":"新宿区","genre":{"name":"ラーメン"},"open":"11:00～15:00","close":"月","photo":{"pc":{"l":"https://imgfp.hotp.jp/a.jpg"},"mobile":{"l":"https://imgfp.hotp.jp/b.jpg"}}}]}}"#
        let shops = HotPepper.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(shops.first?.hours, "11:00～15:00")
        XCTAssertEqual(shops.first?.closedDays, "月")
        XCTAssertEqual(shops.first?.photo, "https://imgfp.hotp.jp/a.jpg")
    }

    func testGoogleParseKeepsHoursAndPhoto() {
        let json = #"{"places":[{"displayName":{"text":"カフェ 森"},"location":{"latitude":35.69,"longitude":139.70},"primaryType":"cafe","regularOpeningHours":{"periods":[{"open":{"day":2,"hour":9,"minute":0},"close":{"day":2,"hour":18,"minute":0}}]},"photos":[{"name":"places/abc/photos/xyz"}]}]}"#
        let shops = GooglePlaces.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(shops.first?.photo, "places/abc/photos/xyz")
        XCTAssertTrue(shops.first?.hours.hasPrefix("G|") ?? false)
    }

    func testMergeKeepsHoursAndPhotoFromOtherSource() {
        let apple = PlaceCandidate(name: "麺屋 こもれび", address: "新宿区", category: "MKPOICategoryRestaurant", latitude: 35.69, longitude: 139.70, distance: 5)
        var pepper = PlaceCandidate(name: "麺屋 こもれび", address: "", category: "genre:ラーメン", latitude: 35.69, longitude: 139.70, distance: 8)
        pepper.hours = "11:00～15:00"
        pepper.photo = "https://imgfp.hotp.jp/a.jpg"
        let merged = PlaceFinder.merge([[apple], [pepper]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.hours, "11:00～15:00")
        XCTAssertEqual(merged.first?.photo, "https://imgfp.hotp.jp/a.jpg")
    }

    func testOldCandidatesStillDecode() throws {
        let json = #"{"name":"店","address":"","category":"","latitude":35,"longitude":139,"distance":10}"#
        let c = try JSONDecoder().decode(PlaceCandidate.self, from: Data(json.utf8))
        XCTAssertEqual(c.hours, "")
        XCTAssertFalse(c.closedThen)
    }

    // 4. お店の写真（写真のある候補・閉まっていなかった候補だけ、4 軒まで）
    func testLookAlikePickable() {
        var list: [PlaceCandidate] = []
        for i in 0..<7 {
            var c = PlaceCandidate(name: "店\(i)", address: "", category: "", latitude: 35, longitude: 139, distance: Double(i))
            c.photo = i == 1 ? "" : "https://imgfp.hotp.jp/\(i).jpg"
            c.closedThen = i == 2
            list.append(c)
        }
        XCTAssertEqual(LookAlike.pickable(list).map(\.name), ["店0", "店3", "店4", "店5"])
    }

    // 3. 試験の当たりの判定
    func testEvalHit() {
        XCTAssertTrue(EvalStore.isHit(truthName: "麺屋 こもれび 新宿店", truthLat: 35.69, truthLon: 139.70,
                                      gotName: "麺屋こもれび", gotLat: nil, gotLon: nil))
        XCTAssertFalse(EvalStore.isHit(truthName: "麺屋 こもれび", truthLat: 35.69, truthLon: 139.70,
                                       gotName: "カフェ 森", gotLat: 35.69, gotLon: 139.70))
        XCTAssertFalse(EvalStore.isHit(truthName: "麺屋 こもれび", truthLat: 35.69, truthLon: 139.70,
                                       gotName: nil, gotLat: nil, gotLon: nil))
    }

    func testForcedModel() {
        XCTAssertEqual(AIModel.main, "claude-sonnet-5-5")
        AIModel.forced = "claude-opus-5-5"
        XCTAssertEqual(AIModel.main, "claude-opus-5-5")
        XCTAssertEqual(AIModel.light, "claude-opus-5-5")
        AIModel.forced = nil
        XCTAssertEqual(AIModel.light, "claude-haiku-5-5")
    }
}
