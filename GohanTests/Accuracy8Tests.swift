import UIKit
import XCTest
@testable import Gohan

/// 2026-11-26 精度の施策 8 つ（本人「1・2・3・4・5・6・9・10」）。通信も写真も使わない決め方のところだけ確かめる
final class Accuracy8Tests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func photo(_ id: String, minutes: Double, lat: Double? = 35.6900, lon: Double? = 139.7000, food: Double = 0.9,
                       accuracy: Double = 20, altitude: Double? = nil, altitudeAccuracy: Double? = nil) -> SeenPhoto {
        SeenPhoto(id: id, date: base.addingTimeInterval(minutes * 60), latitude: lat, longitude: lon, accuracy: accuracy,
                  food: food, label: "ramen", altitude: altitude, altitudeAccuracy: altitudeAccuracy)
    }

    private func shop(_ name: String, category: String = "", lat: Double = 35.6900, lon: Double = 139.7000, distance: Double = 30) -> PlaceCandidate {
        PlaceCandidate(name: name, address: "", category: category, latitude: lat, longitude: lon, distance: distance)
    }

    private func visit(from: Double, to: Double?, lat: Double = 35.6900, lon: Double = 139.7000) -> Visit {
        Visit(arrival: base.addingTimeInterval(from * 60), departure: to.map { base.addingTimeInterval($0 * 60) },
              latitude: lat, longitude: lon, accuracy: 30)
    }

    // MARK: - 案1 自分の過去の写真と見比べる

    func testPackedPrintKeepsDirection() {
        let v: [Float] = [0.02, -0.11, 0.30, 0.0, 0.07]
        let back = OwnPhotos.unpack(OwnPhotos.pack(v))
        XCTAssertEqual(back.count, v.count)
        XCTAssertGreaterThan(OwnPhotos.cosine(v, back), 0.999)
        // 長さが違う・空は「似ていない」
        XCTAssertEqual(OwnPhotos.cosine(v, [1, 2]), 0)
        XCTAssertEqual(OwnPhotos.cosine([], []), 0)
        XCTAssertEqual(OwnPhotos.unpack(OwnPhotos.pack([0, 0, 0])), [0, 0, 0])
    }

    func testMatchesPickThePlaceWithTheClosestPhoto() {
        let ramen: [Float] = [1, 0.1, 0, 0]
        let cafe: [Float] = [0, 0, 1, 0.2]
        let known = [
            PhotoPrint(photoID: "r1", placeKey: "ramen", packed: OwnPhotos.pack(ramen)),
            PhotoPrint(photoID: "r2", placeKey: "ramen", packed: OwnPhotos.pack([0.9, 0.3, 0, 0])),
            PhotoPrint(photoID: "c1", placeKey: "cafe", packed: OwnPhotos.pack(cafe)),
        ]
        let found = OwnPhotos.matches([[1, 0.12, 0, 0]], known: known)
        XCTAssertEqual(found.first?.placeKey, "ramen")
        XCTAssertEqual(OwnPhotos.hints(found).map(\.placeKey), ["ramen"])
        XCTAssertTrue(OwnPhotos.isClear(found))
        // 同じ写真（いまの食事の写真）は比べない
        XCTAssertEqual(OwnPhotos.matches([ramen], known: known, skip: ["r1", "r2"]).first?.placeKey, "cafe")
        XCTAssertTrue(OwnPhotos.hints(OwnPhotos.matches([ramen], known: known, skip: ["r1", "r2"])).isEmpty)
        XCTAssertTrue(OwnPhotos.matches([], known: known).isEmpty)
    }

    func testTwoPlacesThatLookTheSameAreNotClear() {
        let known = [
            PhotoPrint(photoID: "a", placeKey: "A", packed: OwnPhotos.pack([1, 0.1, 0])),
            PhotoPrint(photoID: "b", placeKey: "B", packed: OwnPhotos.pack([1, 0.12, 0])),
        ]
        let found = OwnPhotos.matches([[1, 0.11, 0]], known: known)
        XCTAssertEqual(OwnPhotos.hints(found).count, 2)
        XCTAssertFalse(OwnPhotos.isClear(found))
    }

    func testPrintsAreCappedPerPlaceAndReplaceTheSamePhoto() {
        var all: [PhotoPrint] = []
        for i in 0..<12 { all = OwnPhotos.adding([PhotoPrint(photoID: "p\(i)", placeKey: "A", packed: Data([1]))], to: all) }
        XCTAssertEqual(all.count, OwnPhotos.perPlace)
        XCTAssertEqual(all.last?.photoID, "p11")
        XCTAssertFalse(all.contains { $0.photoID == "p0" })
        // 同じ写真は、お店を付けかえて 1 つだけ残る
        all = OwnPhotos.adding([PhotoPrint(photoID: "p11", placeKey: "B", packed: Data([1]))], to: all)
        XCTAssertEqual(all.filter { $0.photoID == "p11" }.map(\.placeKey), ["B"])
    }

    func testAlikeShopMovesUpButOnlyALittle() {
        var far = shop("前に行った店", distance: 60)
        far.score = 0.40
        far.alike = true
        var near = shop("近い店", distance: 10)
        near.score = 0.45
        XCTAssertEqual(Matcher.applyAlike([near, far]).first?.name, "前に行った店")
        var strong = near
        strong.score = 0.70
        XCTAssertEqual(Matcher.applyAlike([strong, far]).first?.name, "近い店")
    }

    func testLookAlikeLabelSaysWhosePhotos() {
        var s = shop("麺屋こもれび", distance: 42)
        XCTAssertEqual(LookAlike.label(index: 1, shop: s, count: 2, mine: true), "候補 1: 麺屋こもれび（42m）で、この人が前に撮った写真（2 枚）")
        s.distance = PlaceCandidate.unknownDistance
        XCTAssertEqual(LookAlike.label(index: 0, shop: s, count: 1, mine: false), "候補 0: 麺屋こもれびの紹介写真（1 枚）")
    }

    // MARK: - 案2 同じ場所の迷いを埋める

    func testRetroFillOnlyTouchesUnsureMealsAtTheSameSpot() {
        func other(place: Bool, confidence: Double, genre: String = "ラーメン", distance: Double? = 20) -> RetroFix.Other {
            RetroFix.Other(hasPlace: place, confidence: confidence, genre: genre, distance: distance)
        }
        // お店が無い・迷っている → 埋める
        XCTAssertTrue(RetroFix.shouldFill(other(place: false, confidence: 0), sureGenre: "ラーメン", shopGenre: "ラーメン"))
        XCTAssertTrue(RetroFix.shouldFill(other(place: true, confidence: 0.4), sureGenre: "ラーメン", shopGenre: nil))
        // ごく近いジャンル（ラーメンとつけ麺）は埋める。お店の名前から分かるジャンルが合うときも
        XCTAssertTrue(RetroFix.shouldFill(other(place: false, confidence: 0.3, genre: "つけ麺"), sureGenre: "ラーメン", shopGenre: nil))
        XCTAssertTrue(RetroFix.shouldFill(other(place: false, confidence: 0.3, genre: "寿司"), sureGenre: "和食", shopGenre: "寿司"))
        // ジャンル不明・広いなかま（和食どうし）というだけでは埋めない（フードコートや飲食店ビルの別のお店かもしれない）
        XCTAssertFalse(RetroFix.shouldFill(other(place: false, confidence: 0.3, genre: "その他"), sureGenre: "ラーメン", shopGenre: nil))
        XCTAssertFalse(RetroFix.shouldFill(other(place: false, confidence: 0.3, genre: "定食"), sureGenre: "寿司", shopGenre: "寿司"))
        // 自信のある食事・本人が決めた食事には触らない
        XCTAssertFalse(RetroFix.shouldFill(other(place: true, confidence: 0.8), sureGenre: "ラーメン", shopGenre: "ラーメン"))
        XCTAssertFalse(RetroFix.shouldFill(other(place: false, confidence: 1), sureGenre: "ラーメン", shopGenre: "ラーメン"))
        // 遠い・位置が無い・料理の系統が違う（同じビルの別のお店かもしれない）
        XCTAssertFalse(RetroFix.shouldFill(other(place: false, confidence: 0, distance: 80), sureGenre: "ラーメン", shopGenre: "ラーメン"))
        XCTAssertFalse(RetroFix.shouldFill(other(place: false, confidence: 0, distance: nil), sureGenre: "ラーメン", shopGenre: "ラーメン"))
        XCTAssertFalse(RetroFix.shouldFill(other(place: false, confidence: 0, genre: "カフェ"), sureGenre: "ラーメン", shopGenre: "ラーメン"))
        // おうち・職場・消した食事
        var home = other(place: false, confidence: 0)
        home.atHomeOrWork = true
        XCTAssertFalse(RetroFix.shouldFill(home, sureGenre: "ラーメン", shopGenre: nil))
        var hidden = other(place: false, confidence: 0)
        hidden.hidden = true
        XCTAssertFalse(RetroFix.shouldFill(hidden, sureGenre: "ラーメン", shopGenre: nil))
        // 埋めた食事は「たぶん」のまま
        XCTAssertLessThan(RetroFix.filledConfidence, Matcher.sureLine)
    }

    // MARK: - 案3 文字を大きく切り出す

    func testZoomRegionCoversSmallText() throws {
        let size = CGSize(width: 1024, height: 768)
        // 遠くの看板: 小さな字が 2 行（高さ 1.5%）
        let boxes = [CGRect(x: 0.40, y: 0.20, width: 0.20, height: 0.015), CGRect(x: 0.42, y: 0.24, width: 0.16, height: 0.015)]
        let unit = try XCTUnwrap(TextZoom.region(boxes, imageSize: size))
        XCTAssertTrue(unit.contains(boxes[0]) && unit.contains(boxes[1]))
        XCTAssertLessThan(unit.width * unit.height, 0.2)
        XCTAssertFalse(TextZoom.isWide(unit))
        // 大きな字だけ・1 行だけなら切り出さない
        XCTAssertNil(TextZoom.region([CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.12), CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.12)], imageSize: size))
        XCTAssertNil(TextZoom.region([boxes[0]], imageSize: size))
        XCTAssertNil(TextZoom.region([], imageSize: size))
        // 縦書き（箱が細長い）は、箱の幅が字の大きさ
        let vertical = [CGRect(x: 0.30, y: 0.10, width: 0.012, height: 0.30), CGRect(x: 0.33, y: 0.10, width: 0.012, height: 0.25)]
        XCTAssertNotNil(TextZoom.region(vertical, imageSize: size))
    }

    func testZoomOfAFullPageMenuIsWide() throws {
        let size = CGSize(width: 768, height: 1024)
        let boxes = (0..<20).map { CGRect(x: 0.08, y: 0.05 + Double($0) * 0.045, width: 0.84, height: 0.018) }
        let unit = try XCTUnwrap(TextZoom.region(boxes, imageSize: size))
        XCTAssertTrue(TextZoom.isWide(unit))
        XCTAssertGreaterThanOrEqual(unit.minX, 0)
        XCTAssertLessThanOrEqual(unit.maxY, 1)
    }

    func testZoomMustBeClearlyBigger() {
        let unit = CGRect(x: 0.4, y: 0.2, width: 0.25, height: 0.1)
        // 縮めた写真では 1024 × 0.25 = 256 px。切り出しが 1000 px なら大きい・300 px なら大きくならない
        XCTAssertTrue(TextZoom.isBigger(CGSize(width: 1000, height: 400), unit: unit))
        XCTAssertFalse(TextZoom.isBigger(CGSize(width: 300, height: 120), unit: unit))
    }

    func testCropKeepsTheRegionAndTheLimit() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let cut = try XCTUnwrap(TextZoom.crop(image, unit: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), maxSide: 100))
        XCTAssertEqual(max(cut.size.width, cut.size.height), 100, accuracy: 1)
        XCTAssertEqual(cut.size.width / cut.size.height, 400.0 / 300.0, accuracy: 0.05)
        // 小さすぎる範囲は切り出さない
        XCTAssertNil(TextZoom.crop(image, unit: CGRect(x: 0, y: 0, width: 0.001, height: 0.001), maxSide: 100))
    }

    // MARK: - 案4 訪問の記録で食事を区切る

    func testSameStayKeepsALongDinnerTogether() {
        // 同じ所に 3 時間いた。写真の間は 120 分（時間の決まりだけなら 90 分で割れる）
        let visits = [visit(from: -10, to: 170)]
        let photos = [photo("乾杯", minutes: 0), photo("しめ", minutes: 120)]
        XCTAssertEqual(Matcher.groupMeals(photos, visits: visits).count, 1)
        XCTAssertEqual(Matcher.groupMeals(photos).count, 2)
        // 同じ滞在でも、150 分より長くあけば別の食事
        XCTAssertEqual(Matcher.groupMeals([photo("a", minutes: 0), photo("b", minutes: 160)], visits: visits).count, 2)
    }

    func testMovingToAnotherPlaceSplitsEvenIfSoon() {
        // 30 分後・150m 先の別のお店（時間と距離の決まりだけなら 1 回の食事になる）
        let visits = [visit(from: -20, to: 12), visit(from: 18, to: 60, lat: 35.6913)]
        let photos = [photo("ラーメン", minutes: 0), photo("二軒目", minutes: 30, lat: 35.6913)]
        XCTAssertEqual(Matcher.groupMeals(photos, visits: visits).count, 2)
        XCTAssertEqual(Matcher.groupMeals(photos).count, 1)
    }

    func testVisitLinkIsCarefulWhenItCannotTell() {
        let stay = visit(from: 0, to: 60)
        XCTAssertEqual(VisitLog.link([stay], base.addingTimeInterval(10 * 60), base.addingTimeInterval(50 * 60), now: base), .sameStay)
        // 訪問の記録が無い・片方しか入っていない → 分からない（時間の決まりで決める）
        XCTAssertEqual(VisitLog.link([], base, base.addingTimeInterval(600), now: base), .unknown)
        XCTAssertEqual(VisitLog.link([stay], base.addingTimeInterval(10 * 60), base.addingTimeInterval(200 * 60), now: base), .unknown)
        // 家や職場のような長い滞在（4 時間より長い）は、区切りに使わない
        let home = visit(from: 0, to: 600)
        XCTAssertEqual(VisitLog.link([home], base.addingTimeInterval(60 * 60), base.addingTimeInterval(120 * 60), now: base), .unknown)
        // 別の訪問でも、ほぼ同じ所（記録が途中で切れただけかも）なら決めつけない
        let again = visit(from: 70, to: 120, lat: 35.69002)
        XCTAssertEqual(VisitLog.link([stay, again], base.addingTimeInterval(30 * 60), base.addingTimeInterval(90 * 60), now: base), .unknown)
        let moved = visit(from: 70, to: 120, lat: 35.6920)
        XCTAssertEqual(VisitLog.link([stay, moved], base.addingTimeInterval(30 * 60), base.addingTimeInterval(90 * 60), now: base), .moved)
    }

    // MARK: - 案5 料理の種類で探し直す

    func testGenreSearchWord() {
        XCTAssertEqual(Matcher.genreSearchWord("ラーメン"), "ラーメン")
        XCTAssertEqual(Matcher.genreSearchWord("そば・うどん", dishes: ["肉うどん"]), "うどん")
        XCTAssertEqual(Matcher.genreSearchWord("そば・うどん", dishes: ["ざるそば"]), "そば")
        XCTAssertEqual(Matcher.genreSearchWord("中華"), "中華料理")
        // 広すぎるジャンルは探さない
        XCTAssertNil(Matcher.genreSearchWord("その他"))
        XCTAssertNil(Matcher.genreSearchWord("和食"))
        XCTAssertNil(Matcher.genreSearchWord("知らないジャンル"))
    }

    func testLacksGenre() {
        let cafe = shop("喫茶ひだまり", category: "MKPOICategoryCafe")
        let ramen = shop("麺屋こもれび")
        XCTAssertTrue(Matcher.lacksGenre([cafe], genre: "ラーメン"))
        XCTAssertFalse(Matcher.lacksGenre([cafe, ramen], genre: "ラーメン"))
        XCTAssertTrue(Matcher.lacksGenre([], genre: "ラーメン"))
    }

    // MARK: - 案6 お店の一言

    func testHotPepperNoteComesFromTheCatchCopy() {
        let json = #"{"results":{"shop":[{"name":"麺屋 こもれび","lat":35.69,"lng":139.70,"address":"新宿区","genre":{"name":"ラーメン","catch":"行列のできる一杯"},"sub_genre":{"name":"つけ麺"},"catch":"濃厚魚介の<br>つけ麺が自慢\nの店"},{"name":"名なしの店","lat":35.69,"lng":139.70,"genre":{"name":"居酒屋","catch":"仕事帰りに一杯"}}]}}"#
        let shops = HotPepper.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(shops.first?.note, "つけ麺・濃厚魚介のつけ麺が自慢 の店")
        // お店の紹介文が無ければ、ジャンルの紹介文
        XCTAssertEqual(shops.last?.note, "仕事帰りに一杯")
        XCTAssertLessThanOrEqual(HotPepper.note(shop: String(repeating: "あ", count: 200), genre: "", sub: "").count, 60)
    }

    func testOpenStreetMapNoteHasCuisineAndFloor() {
        XCTAssertEqual(OSMPlaces.note(["cuisine": "ramen;tsukemen", "level": "1"]), "ramen・tsukemen・2 階")
        XCTAssertEqual(OSMPlaces.note(["level": "-1"]), "地下 1 階")
        XCTAssertEqual(OSMPlaces.note(["amenity": "restaurant"]), "")
    }

    func testNoteIsShownToTheAIButNeverSaved() throws {
        var c = shop("麺屋こもれび", category: "genre:ラーメン")
        c.note = "濃厚魚介のつけ麺が自慢"
        c.alike = true
        c.facing = true
        let prompt = ClaudeVision.prompt(date: Date(), area: "新宿", candidates: [c], lines: [], foodCount: 1, clueCount: 0)
        XCTAssertTrue(prompt.contains("／濃厚魚介のつけ麺が自慢"))
        XCTAssertTrue(prompt.contains("前にここで撮った写真と似ている"))
        XCTAssertTrue(prompt.contains("看板などの写真が向いていた先"))
        // 保存するときは、その場かぎりの手がかりを入れない（ホットペッパーの紹介文は長く置けない）
        let data = try JSONEncoder().encode([c])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("濃厚魚介"))
        let back = try JSONDecoder().decode([PlaceCandidate].self, from: data)
        XCTAssertEqual(back.first?.name, "麺屋こもれび")
        XCTAssertEqual(back.first?.note, "")
        XCTAssertEqual(back.first?.alike, false)
    }

    func testMergeKeepsNotesAndMarks() {
        var apple = shop("麺屋こもれび", distance: 20)
        apple.facing = true
        var pepper = shop("麺屋こもれび", category: "genre:ラーメン", distance: 25)
        pepper.note = "濃厚魚介"
        var mine = shop("麺屋こもれび", distance: 22)
        mine.note = "料理: 特製つけ麺"
        mine.alike = true
        let merged = PlaceFinder.merge([[apple], [pepper], [mine]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.note, "濃厚魚介／料理: 特製つけ麺")
        XCTAssertTrue(merged.first?.alike ?? false)
        XCTAssertTrue(merged.first?.facing ?? false)
    }

    func testPromptWithoutLocationHidesDistance() {
        var c = shop("麺屋こもれび", distance: PlaceCandidate.unknownDistance)
        c.alike = true
        let prompt = ClaudeVision.prompt(date: Date(), area: "", candidates: [c], lines: [], foodCount: 1, clueCount: 0,
                                         zoomCount: 2, hints: ["料理の写真は、お店の外で撮った写真より約 9m 高い所で撮られています。"], located: false)
        XCTAssertTrue(prompt.contains("距離は不明"))
        XCTAssertFalse(prompt.contains("99999"))
        XCTAssertTrue(prompt.contains("写真に場所が無い"))
        XCTAssertTrue(prompt.contains("最後の 2 枚は"))
        XCTAssertTrue(prompt.contains("約 9m 高い所"))
    }

    // MARK: - 案9 写真の向きと高さ

    func testBearingAndGap() {
        XCTAssertEqual(Matcher.bearing(35.69, 139.70, 35.70, 139.70), 0, accuracy: 0.5)      // 北
        XCTAssertEqual(Matcher.bearing(35.69, 139.70, 35.69, 139.71), 90, accuracy: 0.5)     // 東
        XCTAssertEqual(Matcher.bearing(35.69, 139.70, 35.68, 139.70), 180, accuracy: 0.5)    // 南
        XCTAssertEqual(Matcher.bearing(35.69, 139.70, 35.69, 139.69), 270, accuracy: 0.5)    // 西
        XCTAssertEqual(Matcher.angleGap(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(Matcher.angleGap(10, 350), 20, accuracy: 0.001)
        XCTAssertEqual(Matcher.angleGap(90, 270), 180, accuracy: 0.001)
    }

    func testShopInFrontOfTheCameraMovesUp() {
        // 撮った所から北へ 33m のお店と、南へ 33m のお店。カメラは北を向いていた
        var north = shop("北の店", lat: 35.6903)
        north.score = 0.40
        var south = shop("南の店", lat: 35.6897)
        south.score = 0.44
        let shot = Matcher.Shot(latitude: 35.6900, longitude: 139.7000, heading: 5)
        let ranked = Matcher.applyDirection([south, north], shots: [shot])
        XCTAssertEqual(ranked.first?.name, "北の店")
        XCTAssertTrue(ranked.first?.facing ?? false)
        XCTAssertFalse(ranked.last?.facing ?? true)
        XCTAssertEqual(ranked.last?.score ?? 0, 0.44, accuracy: 0.0001)
        // 向きの分からないときは何も変えない
        XCTAssertEqual(Matcher.applyDirection([south, north], shots: []).first?.name, "南の店")
        // 近すぎる（8m より近い）お店は、向きで決めない
        let here = shop("ここの店", lat: 35.69003)
        XCTAssertFalse(Matcher.applyDirection([here], shots: [shot]).first?.facing ?? true)
    }

    func testFloorHintNeedsSureHeights() {
        let table = [photo("料理", minutes: 0, altitude: 52, altitudeAccuracy: 4)]
        let street = [photo("看板", minutes: -5, food: 0, altitude: 40, altitudeAccuracy: 5)]
        XCTAssertEqual(Matcher.floorHint(food: table, outside: street)?.contains("約 12m 高い"), true)
        let basement = [photo("料理", minutes: 0, altitude: 31, altitudeAccuracy: 4)]
        XCTAssertEqual(Matcher.floorHint(food: basement, outside: street)?.contains("地下"), true)
        // 高さがあいまい・差が小さい・外の写真が無い → 言わない
        let vague = [photo("料理", minutes: 0, altitude: 52, altitudeAccuracy: 30)]
        XCTAssertNil(Matcher.floorHint(food: vague, outside: street))
        let same = [photo("料理", minutes: 0, altitude: 43, altitudeAccuracy: 4)]
        XCTAssertNil(Matcher.floorHint(food: same, outside: street))
        XCTAssertNil(Matcher.floorHint(food: table, outside: []))
        XCTAssertNil(Matcher.floorHint(food: [photo("料理", minutes: 0)], outside: street))
    }

    func testOldSeenPhotosDecodeWithoutAltitude() throws {
        let old = #"{"id":"a","date":0,"food":0.9,"label":"ramen"}"#
        let p = try JSONDecoder().decode(SeenPhoto.self, from: Data(old.utf8))
        XCTAssertNil(p.altitude)
        XCTAssertNil(p.altitudeAccuracy)
    }

    // MARK: - 案10 名物で料理名を合わせる

    func testShopMenuParsesTheAnswerAndTheCost() {
        let json = """
        {"model":"claude-sonnet-5-5","stop_reason":"end_turn",
         "usage":{"input_tokens":10000,"output_tokens":500,"server_tool_use":{"web_search_requests":2}},
         "content":[{"type":"server_tool_use","id":"x","name":"web_search","input":{"query":"麺屋こもれび メニュー"}},
                    {"type":"text","text":"調べました。"},
                    {"type":"text","text":"{\\"menu\\": [\\"特製中華そば\\", \\"中華そば\\", \\"\\", \\"中華そば\\"], \\"dishes\\": [\\"特製中華そば\\", \\"餃子\\"]}"}]}
        """
        let (answer, usd) = ShopMenu.parse(Data(json.utf8))
        XCTAssertEqual(answer?.menu, ["特製中華そば", "中華そば"])
        XCTAssertEqual(answer?.dishes, ["特製中華そば", "餃子"])
        // 入力 1 万・出力 500 トークン（Sonnet の値段）と、検索 2 回（1 回 $0.01）
        XCTAssertEqual(usd, 10000 * 2.0 / 1_000_000 + 500 * 10.0 / 1_000_000 + 0.02, accuracy: 0.0001)
        XCTAssertNil(ShopMenu.parse(Data(#"{"content":[{"type":"text","text":"分かりませんでした"}]}"#.utf8)).0)
    }

    func testDishesAreRenamedOnlyWhenTheAnswerLinesUp() {
        XCTAssertEqual(ShopMenu.renamed(old: ["醤油ラーメン", "餃子"], new: ["特製中華そば", "餃子"]), ["特製中華そば", "餃子"])
        // 数が違う・空がある・同じまま → 変えない
        XCTAssertNil(ShopMenu.renamed(old: ["醤油ラーメン", "餃子"], new: ["特製中華そば"]))
        XCTAssertNil(ShopMenu.renamed(old: ["醤油ラーメン"], new: [""]))
        XCTAssertNil(ShopMenu.renamed(old: ["醤油ラーメン"], new: ["醤油ラーメン"]))
        XCTAssertNil(ShopMenu.renamed(old: [], new: []))
    }

    func testMenuIsCheckedOncePerShop() {
        let now = Date()
        XCTAssertTrue(ShopMenu.due(nil, now: now))
        XCTAssertFalse(ShopMenu.due(now.addingTimeInterval(-10 * 86_400), now: now))
        XCTAssertTrue(ShopMenu.due(now.addingTimeInterval(-100 * 86_400), now: now))
        XCTAssertEqual(ShopMenu.note(["特製中華そば", "つけそば"]), "料理: 特製中華そば、つけそば")
        XCTAssertEqual(ShopMenu.note([]), "")
    }
}
