import Foundation
import ImageIO
import Photos

// 写真そのものから取れる、小さな手がかり（2026-11-26 案9・案1・案5）。どれも通信を使わない。

extension PlaceCandidate {
    /// 写真に場所が無いとき（距離が分からない）に入れておく値
    static let unknownDistance = 99_999.0
    var hasDistance: Bool { distance < 50_000 }
}

extension Matcher {
    // MARK: - 写真の向き（案9）

    /// 外で撮った写真 1 枚（撮った所と、カメラが向いていた方角。北が 0・時計回りの度）
    struct Shot: Equatable {
        var latitude: Double
        var longitude: Double
        var heading: Double
    }

    /// a から b を見た方角（北が 0・時計回り・0〜360）
    static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// 2 つの方角のひらき（0〜180）
    static func angleGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// 看板・外観の写真が向いていた先（左右 30 度・8〜120m）にあるお店を、少し上へ。
    /// コンパスは 20 度くらいずれるので、向いていないお店を下げることはしない（仮）
    static func applyDirection(_ ranked: [PlaceCandidate], shots: [Shot]) -> [PlaceCandidate] {
        // 点数を付け直したあと（shots なし）でも、もう印が付いているお店には上乗せする
        guard !shots.isEmpty || ranked.contains(where: \.facing) else { return ranked }
        return ranked.map { c in
            var c = c
            for shot in shots {
                let d = distance(shot.latitude, shot.longitude, c.latitude, c.longitude)
                guard d >= 8, d <= 120 else { continue }
                if angleGap(shot.heading, bearing(shot.latitude, shot.longitude, c.latitude, c.longitude)) <= 30 { c.facing = true }
            }
            if c.facing { c.score = min(1, c.score + 0.08) }
            return c
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - 写真の高さ（案9）

    /// 高さの確かな写真だけで、料理の写真と外の写真の高さを比べる。7m 以上ちがえば、AI への一言を返す。
    /// 屋内の写真は高さがあいまいなことが多いので、めったに出ない（仮）
    static func floorHint(food: [SeenPhoto], outside: [SeenPhoto]) -> String? {
        func sure(_ photos: [SeenPhoto]) -> [Double] {
            photos.compactMap { p -> Double? in
                guard let altitude = p.altitude else { return nil }
                // 高さの確かさが書いてなければ、位置の確かさから見積もる
                let accuracy = p.altitudeAccuracy ?? p.accuracy.map { $0 * 1.5 } ?? 99
                return accuracy > 0 && accuracy <= 12 ? altitude : nil
            }
            .sorted()
        }
        let inside = sure(food), out = sure(outside)
        guard !inside.isEmpty, !out.isEmpty else { return nil }
        let diff = inside[inside.count / 2] - out[out.count / 2]
        guard abs(diff) >= 7 else { return nil }
        let meters = Int(abs(diff).rounded())
        return diff > 0
            ? "料理の写真は、お店の外で撮った写真より約 \(meters)m 高い所で撮られています（2 階より上かもしれません）。"
            : "料理の写真は、お店の外で撮った写真より約 \(meters)m 低い所で撮られています（地下かもしれません）。"
    }

    // MARK: - 自分の過去の写真（案1）

    /// 前に撮った写真と似ているお店を、少し上へ。これだけではお店を決めない（似ているかの線がまだ仮なので、小さな上乗せにする）
    static func applyAlike(_ ranked: [PlaceCandidate]) -> [PlaceCandidate] {
        guard ranked.contains(where: \.alike) else { return ranked }
        return ranked.map { c in
            var c = c
            if c.alike { c.score = min(1, c.score + 0.10) }
            return c
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - 料理の種類で探し直す（案5）

    /// ジャンル → 地図で探すことば。広すぎて探しても絞れないジャンルは nil
    static func genreSearchWord(_ genre: String, dishes: [String] = []) -> String? {
        switch genre {
        case "そば・うどん": return dishes.contains { $0.contains("うどん") } ? "うどん" : "そば"
        case "中華": return "中華料理"
        case "パン": return "ベーカリー"
        case "その他", "和食", "洋食", "定食", "丼", "鍋", "エスニック", "ファストフード": return nil
        default: return Genre.all.contains(genre) ? genre : nil
        }
    }

    /// 候補の中に、そのジャンルのお店が 1 軒も無いか
    static func lacksGenre(_ ranked: [PlaceCandidate], genre: String) -> Bool {
        !ranked.contains { candidateGenre($0) == genre }
    }
}

extension PhotoLoader {
    /// 撮ったときにカメラが向いていた方角（北が 0・時計回りの度）。写真に書いてなければ nil。
    /// 元の写真がこの iPhone に無いとき（iCloud にだけある）は、取りに行かない
    static func direction(_ asset: PHAsset) async -> Double? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .original
        let data: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
        guard let data else { return nil }
        return direction(in: data)
    }

    /// 写真のデータに書いてある向き（磁石の北か本当の北かは見ない。日本でのずれは 10 度より小さい）
    static func direction(in data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let value = (gps[kCGImagePropertyGPSImgDirection] as? NSNumber)?.doubleValue,
              value >= 0, value <= 360 else { return nil }
        return value
    }
}
