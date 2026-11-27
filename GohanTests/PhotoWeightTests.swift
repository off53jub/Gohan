import UIKit
import XCTest
@testable import Gohan

/// 写真を軽く出す・軽く置く（2026-11-27）
final class PhotoWeightTests: XCTestCase {
    func testStepRoundsUpToNearestSize() {
        XCTAssertEqual(ThumbCache.step(64), 160)
        XCTAssertEqual(ThumbCache.step(192), 320)
        XCTAssertEqual(ThumbCache.step(360), 512)
        // AI に送る大きさ（512）は、段にそろえても変わらない
        XCTAssertEqual(ThumbCache.step(512), 512)
        XCTAssertEqual(ThumbCache.step(600), 800)
        XCTAssertEqual(ThumbCache.step(1080), 1200)
        XCTAssertEqual(ThumbCache.step(5000), 2400)
    }

    func testCostCountsPixels() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 5), format: format).image { _ in }
        XCTAssertEqual(ThumbCache.cost(image), 20 * 10 * 4)
    }

    func testPrintInName() {
        let print = String(repeating: "a1", count: 32)
        XCTAssertEqual(ImportedPhotos.printInName(print + "-ABCDEF12.jpg"), print)
        XCTAssertNil(ImportedPhotos.printInName("0B5E8F8A-1111-2222-3333-444455556666.jpg"))
        XCTAssertNil(ImportedPhotos.printInName(String(repeating: "z", count: 64) + "-x.jpg"))
    }

    func testOnlyOldNamesNeedShrink() {
        let new = String(repeating: "0f", count: 32) + "-12345678.jpg"
        let old = "0B5E8F8A-1111-2222-3333-444455556666.jpg"
        let seen = "1B5E8F8A-1111-2222-3333-444455556666.jpg"
        XCTAssertEqual(ImportedPhotos.needsShrink([new, old, seen], checked: [seen]), [old])
    }

    func testUnusedLeavesPhotosOfMeals() {
        let names = ["a.jpg", "b.jpg", "c.jpg"]
        XCTAssertEqual(ImportedPhotos.unused(names, referenced: ["file:a.jpg", "ABC/L0/001", "file:c.jpg"]), ["b.jpg"])
    }

    func testSmallerMakesBigPhotoLighterAndKeepsSize() throws {
        // 細かい模様の大きな写真（縮めて HEIC にすると、はっきり小さくなるはず）
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1500), format: format).image { ctx in
            for i in 0..<300 {
                UIColor(hue: CGFloat(i % 30) / 30, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: (i * 37) % 2000, y: (i * 53) % 1500, width: 120, height: 90))
            }
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
        guard let small = ImportedPhotos.smaller(jpeg) else {
            // HEIC を作れない環境（シミュレーターの一部）では、元のまま置く
            return
        }
        XCTAssertLessThan(Double(small.count), Double(jpeg.count) * ImportedPhotos.worthRatio)
        let back = try XCTUnwrap(UIImage(data: small))
        XCTAssertEqual(max(back.size.width * back.scale, back.size.height * back.scale), CGFloat(ImportedPhotos.keepSide), accuracy: 1)
    }

    func testSmallerGivesUpOnNonImage() {
        XCTAssertNil(ImportedPhotos.smaller(Data("jpeg".utf8)))
    }

    func testSavedPhotoKeepsOriginalFingerprint() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
        let id = try XCTUnwrap(ImportedPhotos.save(jpeg))
        defer { if let url = ImportedPhotos.url(id) { try? FileManager.default.removeItem(at: url) } }
        // 小さく置いても、もとの JPEG と同じ写真だと分かる（入れ直しで写真が二重にならない）
        XCTAssertEqual(ImportedPhotos.digest(of: id), ImportedPhotos.digest(jpeg))
    }
}
