import AVFoundation
import Foundation
import ImageIO
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

    /// 動画の1コマ（便21。真ん中あたり）
    static func videoFrame(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        let avAsset: AVAsset? = await withCheckedContinuation { (cont: CheckedContinuation<AVAsset?, Never>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                cont.resume(returning: avAsset)
            }
        }
        guard let avAsset else { return nil }
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        let time = CMTime(seconds: max(0, asset.duration / 2), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: frame.image)
    }

    /// カメラで撮った写真か（カメラの名前が写真に書いてあるか。便22）。読めないときは「撮った」とみなす
    static func isCameraPhoto(_ asset: PHAsset) async -> Bool {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .original
        let data: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return true }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], tiff[kCGImagePropertyTIFFMake] != nil { return true }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], exif[kCGImagePropertyExifLensModel] != nil { return true }
        return false
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

    /// 人の顔を塗りつぶす（便72。AI に送る前に）
    static func hidingFaces(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation(image), options: [:])
        do { try handler.perform([request]) } catch { return image }
        let faces = request.results ?? []
        guard !faces.isEmpty else { return image }
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            UIColor(hex: 0x9AA3B8).setFill()
            for face in faces {
                let b = face.boundingBox
                let rect = CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height,
                                  width: b.width * size.width, height: b.height * size.height)
                    .insetBy(dx: -b.width * size.width * 0.2, dy: -b.height * size.height * 0.3)
                context.cgContext.fillEllipse(in: rect)
            }
        }
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

    static func orientation(_ image: UIImage) -> CGImagePropertyOrientation {
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
