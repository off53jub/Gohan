import UIKit
import Vision

// 文字のある所を大きく切り出す（2026-11-26 案3）。
// AI には写真全体を長い辺 1024 px に縮めて送っているので、遠くの看板・メニューの小さな字はつぶれて読めない。
// 端末で見つけた小さな字のまとまりを、元の写真の細かさから切り出して、もう 1 枚として送る。
// 切り出した絵は端末でも読み直すので、地図を名前で探すときの文字も良くなる。
enum TextZoom {
    /// 字の大きさ（1 字の辺 ÷ 写真の長い辺）がこれより小さいと、縮めたときにつぶれる（1024 px で約 22 px。仮）
    static let smallGlyph = 0.022
    /// 小さすぎて、切り出しても読めない字（ごみ）は数えない
    static let tinyGlyph = 0.004

    /// 切り出す範囲（左上が原点・0〜1）。小さな字が 2 行より少なければ nil。
    /// boxes は文字の箱（左上が原点・0〜1）、imageSize は写真の縦横
    static func region(_ boxes: [CGRect], imageSize: CGSize) -> CGRect? {
        let long = max(imageSize.width, imageSize.height)
        guard long > 0 else { return nil }
        let small = boxes.filter { box in
            // 横書きなら箱の高さ、縦書きなら箱の幅が、だいたい 1 字の大きさ
            let glyph = min(box.width * imageSize.width, box.height * imageSize.height) / long
            return glyph < smallGlyph && glyph > tinyGlyph
        }
        guard small.count >= 2 else { return nil }
        var union = small.reduce(CGRect.null) { $0.union($1) }
        let padX = max(0.03, union.width * 0.15), padY = max(0.03, union.height * 0.15)
        union = union.insetBy(dx: -padX, dy: -padY).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return union.isNull || union.isEmpty ? nil : union
    }

    /// 写真全体に近い範囲か（メニューを画面いっぱいに撮った写真など。切り出すより、細かいまま送る）
    static func isWide(_ unit: CGRect) -> Bool { unit.width * unit.height > 0.55 }

    /// 範囲を切り出して、長い辺を maxSide までにする（小さいものは、そのまま）
    static func crop(_ image: UIImage, unit: CGRect, maxSide: CGFloat) -> UIImage? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        let rect = CGRect(x: unit.minX * w, y: unit.minY * h, width: unit.width * w, height: unit.height * h)
        guard rect.width >= 80, rect.height >= 40 else { return nil }
        let k = min(1, maxSide / max(rect.width, rect.height))
        let size = CGSize(width: (rect.width * k).rounded(), height: (rect.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: -rect.minX * k, y: -rect.minY * k, width: w * k, height: h * k))
        }
    }

    /// 切り出した絵が、縮めた写真（長い辺 shown px）の同じ所より、はっきり大きいか（元の写真が小さいと大きくならない）
    static func isBigger(_ cut: CGSize, unit: CGRect, shown: CGFloat = 1024) -> Bool {
        max(cut.width, cut.height) >= 1.3 * shown * max(unit.width, unit.height)
    }
}

extension PhotoVision {
    /// 写真の中の文字と、その場所（左上が原点・0〜1）
    static func textBoxes(_ image: UIImage) -> [(text: String, box: CGRect)] {
        guard let cg = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation(image), options: [:])
        do { try handler.perform([request]) } catch { return [] }
        var out: [(text: String, box: CGRect)] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string, Matcher.normalize(text).count >= 2 else { continue }
            let b = observation.boundingBox
            out.append((text, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)))
        }
        return out
    }
}
