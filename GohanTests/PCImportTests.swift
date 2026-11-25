import UIKit
import XCTest
@testable import Gohan

/// PC から取り込む（2026-11-25）
final class PCImportTests: XCTestCase {
    private let sample = #"""
    {"kind":"gohan.import","version":1,"made":"2026-11-25T08:00:00+09:00","source":"pCloud","meals":[
      {"date":"2026-11-01T18:46:44+09:00","endDate":"2026-11-01T19:20:00+09:00","latitude":35.6975,"longitude":139.6691,"accuracy":20.6,
       "verdict":{"is_meal":true,"eaten_out":true,"place_index":-1,"place_confidence":0,"genre":"焼肉","dishes":["牛タン","ライス"],
                  "summary":"厚切り牛タンとごはん","kind":"meal","reason":"","name_seen":"牛タン 炭火"},
       "lines":["炭火焼肉"],
       "photos":[{"date":"2026-11-01T18:46:44+09:00","jpeg":"/9j/4AAQ"}]}
    ]}
    """#

    func testDecodesFileFromPC() throws {
        let file = try PCImport.decode(Data(sample.utf8))
        XCTAssertEqual(file.source, "pCloud")
        XCTAssertEqual(file.meals.count, 1)
        let meal = file.meals[0]
        XCTAssertEqual(meal.verdict.genre, "焼肉")
        XCTAssertEqual(meal.verdict.dishes, ["牛タン", "ライス"])
        XCTAssertEqual(meal.verdict.name_seen, "牛タン 炭火")
        XCTAssertEqual(meal.lines, ["炭火焼肉"])
        XCTAssertEqual(meal.photos.first?.jpeg, Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
        XCTAssertEqual(meal.endDate.timeIntervalSince(meal.date), 33 * 60 + 16)
    }

    func testPlaceFromPCIsOptional() throws {
        XCTAssertNil(try PCImport.decode(Data(sample.utf8)).meals[0].place)
        let withPlace = sample.replacingOccurrences(
            of: #""lines":["炭火焼肉"],"#,
            with: #""lines":["炭火焼肉"],"place":{"name":"炭火焼肉 たん","latitude":35.6976,"longitude":139.6690,"confidence":0.8,"reason":"看板と場所が合った"},"#)
        let place = try XCTUnwrap(PCImport.decode(Data(withPlace.utf8)).meals[0].place)
        XCTAssertEqual(place.name, "炭火焼肉 たん")
        XCTAssertEqual(place.confidence, 0.8)
        XCTAssertEqual(place.latitude, 35.6976)
    }

    func testRejectsOtherFiles() {
        let backup = #"{"kind":"something","meals":[]}"#
        XCTAssertThrowsError(try PCImport.decode(Data(backup.utf8)))
    }

    func testDuplicateNeedsSameTimeAndPlace() throws {
        let meal = try PCImport.decode(Data(sample.utf8)).meals[0]
        let sameTime = meal.date.addingTimeInterval(20 * 60)
        XCTAssertTrue(PCImport.isDuplicate(meal, existing: [(sameTime, 35.6976, 139.6692)]))
        XCTAssertTrue(PCImport.isDuplicate(meal, existing: [(sameTime, nil, nil)]))
        XCTAssertFalse(PCImport.isDuplicate(meal, existing: [(sameTime, 35.70, 139.75)]))
        XCTAssertFalse(PCImport.isDuplicate(meal, existing: [(meal.date.addingTimeInterval(-3 * 3600), 35.6975, 139.6691)]))
    }

    func testImportedPhotoIDs() async throws {
        XCTAssertTrue(ImportedPhotos.isFile("file:abc.jpg"))
        XCTAssertFalse(ImportedPhotos.isFile("ABC-123/L0/001"))
        XCTAssertNil(ImportedPhotos.url("file:../secret"))
        XCTAssertNil(ImportedPhotos.url("file:"))

        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let id = try XCTUnwrap(ImportedPhotos.save(try XCTUnwrap(image.jpegData(compressionQuality: 0.8))))
        let loaded = await ImportedPhotos.image(id, side: 64)
        XCTAssertNotNil(loaded)
        XCTAssertLessThanOrEqual(max(loaded?.size.width ?? 99, loaded?.size.height ?? 99), 64)
        if let url = ImportedPhotos.url(id) { try? FileManager.default.removeItem(at: url) }
    }

    func testSamePhotoHasSameFingerprint() throws {
        let data = Data("jpeg".utf8)
        let id = try XCTUnwrap(ImportedPhotos.save(data))
        XCTAssertEqual(ImportedPhotos.digest(of: id), ImportedPhotos.digest(data))
        XCTAssertNotEqual(ImportedPhotos.digest(data), ImportedPhotos.digest(Data("other".utf8)))
        if let url = ImportedPhotos.url(id) { try? FileManager.default.removeItem(at: url) }
    }

    func testMatchPicksClosestMeal() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let meal = ImportMeal(date: base, endDate: base, latitude: nil, longitude: nil, accuracy: nil,
                              verdict: MealVerdict(is_meal: true, eaten_out: true, place_index: -1, place_confidence: 0,
                                                   genre: "ラーメン", dishes: [], summary: "", kind: "meal", reason: "", name_seen: ""),
                              photos: [])
        let existing: [(date: Date, latitude: Double?, longitude: Double?)] = [
            (base.addingTimeInterval(-40 * 60), nil, nil), (base.addingTimeInterval(5 * 60), nil, nil), (base.addingTimeInterval(3 * 3600), nil, nil),
        ]
        XCTAssertEqual(PCImport.matchIndex(meal, existing: existing), 1)
        XCTAssertNil(PCImport.matchIndex(meal, existing: [existing[2]]))
    }
}
