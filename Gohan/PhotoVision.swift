import Foundation
import Photos
import UIKit
import Vision

/// 写真アプリから絵を取り出す
enum PhotoLoader {
    static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// 長い辺が side くらいの絵（iCloud にしか無い写真も取りに行く）
    static func image(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let size = CGSize(width: side, height: side)
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            var done = false
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                // 高い質を頼んだので1回だけ呼ばれるはずだが、念のため2回目は無視する
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded || done { return }
                done = true
                cont.resume(returning: image)
            }
        }
    }

    /// AI に送る JPEG（長い辺 1024 px まで）
    static func jpeg(_ asset: PHAsset, side: CGFloat = 1024) async -> Data? {
        guard let image = await image(asset, side: side) else { return nil }
        return image.jpegData(compressionQuality: 0.7)
    }
}

/// 写真に何が写っているか（端末の中だけで見る）
enum PhotoVision {
    /// 食べ物・飲み物とみなす Vision のラベル（無い名前はただ当たらないだけ）
    static let foodLabels: Set<String> = [
        "food", "meal", "dish", "dessert", "baked_goods", "bread", "cake", "cookie", "cupcake", "donut", "pastry", "pie",
        "ice_cream", "candy", "chocolate", "fruit", "vegetable", "salad", "sandwich", "burger", "hamburger", "hotdog",
        "pizza", "pasta", "spaghetti", "noodles", "ramen", "sushi", "sashimi", "rice", "curry", "soup", "steak", "meat",
        "seafood", "egg", "breakfast", "dumpling", "taco", "burrito", "fries", "fried_chicken", "pancake", "waffle",
        "coffee", "tea", "cocktail", "wine", "beer", "juice", "smoothie", "drink", "beverage", "barbecue", "sausage",
        "bento", "tofu", "omelet", "crepe", "macaron", "parfait",
    ]
    /// 料理の名前としては使わない、大きすぎるラベル
    static let broadLabels: Set<String> = ["food", "meal", "dish", "drink", "beverage", "fruit", "vegetable"]

    struct Look {
        var food: Double
        var label: String
    }

    static func look(_ image: UIImage) -> Look {
        guard let cg = image.cgImage else { return Look(food: 0, label: "") }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation(image), options: [:])
        do { try handler.perform([request]) } catch { return Look(food: 0, label: "") }
        let results = request.results ?? []
        var food = 0.0
        var label = ""
        var labelScore = 0.0
        for observation in results where foodLabels.contains(observation.identifier) {
            let c = Double(observation.confidence)
            food = max(food, c)
            if !broadLabels.contains(observation.identifier), c > labelScore {
                labelScore = c
                label = observation.identifier
            }
        }
        if label.isEmpty, food > 0 { label = "food" }
        return Look(food: food, label: label)
    }

    /// 写真の中の文字（日本語と英語）
    static func text(_ image: UIImage) -> [String] {
        guard let cg = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation(image), options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.filter { Matcher.normalize($0).count >= 2 }
    }

    private static func orientation(_ image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
