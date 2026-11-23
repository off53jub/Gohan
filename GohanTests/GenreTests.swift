import XCTest
@testable import Gohan

/// ジャンルの見分けと、お店の候補の取り元（2026-11-24）
final class GenreTests: XCTestCase {
    // 本人の例: ラーメンが「スープ」「パスタ」になった
    func testNoodlesAndSoupMeanRamen() {
        XCTAssertEqual(Matcher.genre(fromLabels: ["soup": 0.6, "noodles": 0.3])?.genre, "ラーメン")
        XCTAssertEqual(Matcher.genre(fromLabels: ["pasta": 0.5, "soup": 0.4])?.genre, "ラーメン")
    }

    func testPlatePastaStaysItalian() {
        XCTAssertEqual(Matcher.genre(fromLabels: ["spaghetti": 0.7])?.genre, "イタリアン")
    }

    func testSoupAloneIsNotForced() {
        XCTAssertNil(Matcher.genre(fromLabels: ["soup": 0.7]))
    }

    func testShopNameWins() {
        let g = Matcher.guessGenre(labels: ["pasta": 0.8], lines: [], shopName: "中華そば こもれび", learned: nil)
        XCTAssertEqual(g?.genre, "ラーメン")
        XCTAssertEqual(g?.from, "name")
    }

    func testMenuTextNeedsTwoHits() {
        XCTAssertEqual(Matcher.genre(fromLines: ["醤油らーめん 900円", "味玉らーめん 1050円", "ビール"]), "ラーメン")
        XCTAssertNil(Matcher.genre(fromLines: ["らーめん", "コーヒー"]))
    }

    func testSobaShopIsNotRamen() {
        XCTAssertEqual(Matcher.genre(fromText: "手打ちそば 松屋"), "そば・うどん")
        XCTAssertEqual(Matcher.genre(fromText: "支那そば やま"), "ラーメン")
    }

    func testLearnedGenreBeatsPhoto() {
        let g = Matcher.guessGenre(labels: ["soup": 0.9], lines: [], shopName: nil, learned: "ラーメン")
        XCTAssertEqual(g?.genre, "ラーメン")
    }

    func testGenreMovesRamenShopUp() {
        let cafe = PlaceCandidate(name: "カフェ ドトール", address: "", category: "MKPOICategoryCafe", latitude: 0, longitude: 0, distance: 10, score: 0.5)
        let ramen = PlaceCandidate(name: "麺屋 こもれび", address: "", category: "MKPOICategoryRestaurant", latitude: 0, longitude: 0, distance: 40, score: 0.45)
        let out = Matcher.applyGenre([cafe, ramen], photoGenre: "ラーメン")
        XCTAssertEqual(out.first?.name, "麺屋 こもれび")
    }

    func testMergeLabelsKeepsStrongest() {
        let a = SeenPhoto(id: "a", date: Date(), latitude: nil, longitude: nil, accuracy: nil, food: 0.8, label: "soup", labels: ["soup": 0.8])
        let b = SeenPhoto(id: "b", date: Date(), latitude: nil, longitude: nil, accuracy: nil, food: 0.5, label: "noodles", labels: ["noodles": 0.5, "soup": 0.2])
        XCTAssertEqual(Matcher.mergeLabels([a, b]), ["soup": 0.8, "noodles": 0.5])
    }

    func testHotPepperAndGoogleGenres() {
        XCTAssertEqual(Genre.from(category: "genre:ラーメン"), "ラーメン")
        XCTAssertEqual(Genre.from(category: "google:ramen_restaurant"), "ラーメン")
        XCTAssertNil(Genre.from(category: "google:unknown"))
    }

    func testParseHotPepper() {
        let json = #"{"results":{"shop":[{"name":"麺屋 こもれび","address":"東京都新宿区","lat":35.6905,"lng":"139.7010","genre":{"name":"ラーメン"}}]}}"#
        let list = HotPepper.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(list.first?.name, "麺屋 こもれび")
        XCTAssertEqual(list.first?.category, "genre:ラーメン")
        XCTAssertLessThan(list.first?.distance ?? 9999, 200)
    }

    func testParseGoogle() {
        let json = #"{"places":[{"displayName":{"text":"麺屋 こもれび"},"formattedAddress":"日本、〒160-0022 東京都新宿区","location":{"latitude":35.6905,"longitude":139.701},"primaryType":"ramen_restaurant","nationalPhoneNumber":"03-1234-5678"}]}"#
        let list = GooglePlaces.parse(Data(json.utf8), latitude: 35.69, longitude: 139.70)
        XCTAssertEqual(list.first?.address, "〒160-0022 東京都新宿区")
        XCTAssertEqual(list.first?.phone, "03-1234-5678")
        XCTAssertEqual(Matcher.candidateGenre(list[0]), "ラーメン")
    }

    func testParseWebCheckAnswer() {
        let json = #"{"model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":2}},"content":[{"type":"text","text":"調べました。"},{"type":"text","text":"{\"name\": \"麺屋 こもれび\", \"confidence\": 0.8}"}]}"#
        let (answer, usd) = WebCheck.parse(Data(json.utf8))
        XCTAssertEqual(answer?.name, "麺屋 こもれび")
        XCTAssertEqual(answer?.confidence ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(usd, 0.02, accuracy: 0.0001)
    }

    func testWebCheckEmptyNameIsNil() {
        let json = #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"name\": \"\", \"confidence\": 0}"}]}"#
        XCTAssertNil(WebCheck.parse(Data(json.utf8)).0)
    }

    func testAccuracySummary() {
        let entries = [
            AccuracyEntry(kind: "hit", source: "claude", rank: 0),
            AccuracyEntry(kind: "place", source: "claude", rank: 2),
            AccuracyEntry(kind: "place", source: "device", rank: -1),
            AccuracyEntry(kind: "genre", source: "device"),
        ]
        let s = AccuracyLog.summary(entries)
        XCTAssertEqual(s.hits, 1)
        XCTAssertEqual(s.fixedInList, 1)
        XCTAssertEqual(s.fixedNotInList, 1)
        XCTAssertEqual(s.genreFromPhoto, 1)
    }

    func testVerdictReadsNameSeen() throws {
        let json = #"{"is_meal":true,"eaten_out":true,"place_index":-1,"place_confidence":0.2,"genre":"ラーメン","dishes":["醤油ラーメン"],"summary":"","kind":"meal","reason":"","name_seen":"こもれび"}"#
        XCTAssertEqual(try JSONDecoder().decode(MealVerdict.self, from: Data(json.utf8)).name_seen, "こもれび")
    }
}
