import Foundation
import SwiftData
import UIKit
import Vision

// 自分の過去の写真と見比べる（2026-11-26 案1）。
// 行ったことのあるお店で撮った料理の写真の「見た目の印」（端末の Vision が作る数の並び）を覚えておき、
// 新しい食事の写真と似ているお店を、候補の上に出す。場所の無い写真でも使える。
// 印はこの iPhone の中だけに置く（写真そのものは置かない・どこにも送らない）。
// 似ているかどうかの線はまだ仮（実際の写真で測っていない）。だから、これだけではお店を決めず、
// 候補に入れて AI に知らせるところまでにする。決め手は、迷ったときに AI が過去の写真そのものと見比べるほう。

/// 1 枚の写真の見た目の印（どのお店で撮ったか つき）
struct PhotoPrint: Codable, Equatable {
    var photoID: String
    var placeKey: String
    /// 数の並びを 1 バイトずつに縮めたもの（向きだけ比べるので、大きさは捨ててよい）
    var packed: Data
}

enum OwnPhotos {
    /// これより似ていれば「似ている」とみなす（向きの近さ。1 が同じ。仮）
    static let similarLine: Float = 0.80
    /// ほかのお店より、これだけ上回っていれば「はっきり似ている」（仮）
    static let clearMargin: Float = 0.05
    /// 覚える数（1 軒あたり・ぜんぶで）。古いものから捨てる
    static let perPlace = 8
    static let total = 2000

    struct Match: Equatable {
        var placeKey: String
        var score: Float
    }

    private struct Saved: Codable {
        var prints: [PhotoPrint] = []
        /// 印を作ろうとした食事（写真が見つからなかったものを、何度も試さないため）
        var tried: [String] = []
    }

    private static var url: URL { URL.applicationSupportDirectory.appendingPathComponent("own-photos.json") }
    @MainActor private static var cache: Saved?

    @MainActor private static var saved: Saved {
        get {
            if let cache { return cache }
            var loaded = Saved()
            // 自分で保存したファイル
            if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) { loaded = s }
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: url, options: .atomic) }
        }
    }

    @MainActor static var all: [PhotoPrint] { saved.prints }

    // MARK: - 印を作る・比べる（通信も画面も使わない）

    /// 写真の見た目の印（端末の Vision）。作れなければ nil
    static func vector(of image: UIImage) -> [Float]? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: PhotoVision.orientation(image), options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first, observation.elementType == .float, observation.elementCount > 0 else { return nil }
        var floats = [Float](repeating: 0, count: observation.elementCount)
        let copied = floats.withUnsafeMutableBufferPointer { observation.data.copyBytes(to: $0) }
        return copied == observation.elementCount * MemoryLayout<Float>.size ? floats : nil
    }

    /// 1 バイトずつに縮める（いちばん大きい値が 127 になるように）
    static func pack(_ vector: [Float]) -> Data {
        let top = vector.filter(\.isFinite).map { abs($0) }.max() ?? 0
        guard top > 0 else { return Data(count: vector.count) }
        return Data(vector.map { value -> UInt8 in
            guard value.isFinite else { return 0 }
            return UInt8(bitPattern: Int8(max(-127, min(127, (value / top * 127).rounded()))))
        })
    }

    static func unpack(_ data: Data) -> [Float] {
        data.map { Float(Int8(bitPattern: $0)) }
    }

    /// 向きの近さ（-1〜1。長さが違う・どちらかが空なら 0）
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// 新しい写真（何枚か）に似ているお店を、似ている順に。お店ごとに、いちばん似ている 1 組の近さを使う
    static func matches(_ fresh: [[Float]], known: [PhotoPrint], skip: Set<String> = []) -> [Match] {
        guard !fresh.isEmpty else { return [] }
        var best: [String: Float] = [:]
        for item in known where !skip.contains(item.photoID) {
            let old = unpack(item.packed)
            for vector in fresh {
                let score = cosine(vector, old)
                if score > (best[item.placeKey] ?? -1) { best[item.placeKey] = score }
            }
        }
        return best.map { Match(placeKey: $0.key, score: $0.value) }.sorted { $0.score > $1.score }
    }

    /// 候補に入れてよいお店（似ている線をこえたもの。上から limit 軒）
    static func hints(_ matches: [Match], limit: Int = 3) -> [Match] {
        Array(matches.filter { $0.score >= similarLine }.prefix(limit))
    }

    /// 1 軒だけがはっきり似ているか（ほかのお店の印が無いときは、線をもっと高くする）
    static func isClear(_ matches: [Match]) -> Bool {
        guard let top = matches.first, top.score >= similarLine else { return false }
        guard let second = matches.dropFirst().first else { return top.score >= similarLine + clearMargin }
        return top.score - second.score >= clearMargin
    }

    /// 足したあとの並び（同じ写真は置きかえ・1 軒あたりと全体の上限で古いものから捨てる）
    static func adding(_ new: [PhotoPrint], to old: [PhotoPrint]) -> [PhotoPrint] {
        let ids = Set(new.map(\.photoID))
        var out = old.filter { !ids.contains($0.photoID) } + new
        var count: [String: Int] = [:]
        // 新しいものを残すので、うしろから数える
        var keep: [PhotoPrint] = []
        for item in out.reversed() {
            count[item.placeKey, default: 0] += 1
            if count[item.placeKey, default: 0] <= perPlace { keep.append(item) }
        }
        out = keep.reversed()
        if out.count > total { out.removeFirst(out.count - total) }
        return out
    }

    // MARK: - 覚える・直す

    @MainActor
    static func remember(_ vectors: [(photoID: String, vector: [Float])], placeKey: String) {
        guard !vectors.isEmpty, !placeKey.isEmpty else { return }
        var s = saved
        s.prints = adding(vectors.map { PhotoPrint(photoID: $0.photoID, placeKey: placeKey, packed: pack($0.vector)) }, to: s.prints)
        saved = s
    }

    /// お店を直したとき: その食事の写真の印を、新しいお店に付けかえる（お店でなくなったら捨てる）
    @MainActor
    static func move(photoIDs: [String], to placeKey: String?) {
        let ids = Set(photoIDs)
        var s = saved
        guard s.prints.contains(where: { ids.contains($0.photoID) }) else { return }
        if let placeKey {
            s.prints = s.prints.map { p in
                var p = p
                if ids.contains(p.photoID) { p.placeKey = placeKey }
                return p
            }
        } else {
            s.prints.removeAll { ids.contains($0.photoID) }
        }
        saved = s
    }

    /// まだ印の無い、お店の決まった食事の印を作る（1 回に limit 食まで。新しい食事から）
    @MainActor
    static func backfill(context: ModelContext, limit: Int = 12) async {
        guard AISettings.ownPhotos else { return }
        var s = saved
        let have = Set(s.prints.map(\.photoID))
        var triedList = s.tried
        let tried = Set(triedList)
        var descriptor = FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden && $0.eatenOut },
                                               sortBy: [SortDescriptor(\Meal.date, order: .reverse)])
        descriptor.fetchLimit = 600
        let meals = ((try? context.fetch(descriptor)) ?? []).filter { meal in
            guard meal.place != nil, meal.confidence >= Matcher.sureLine, let first = meal.photoIDs.first else { return false }
            return !have.contains(first) && !tried.contains(meal.id.uuidString)
        }
        guard !meals.isEmpty else { return }
        var new: [PhotoPrint] = []
        for meal in meals.prefix(limit) {
            if Task.isCancelled { break }
            triedList.append(meal.id.uuidString)
            guard let key = meal.place?.key else { continue }
            for id in meal.photoIDs.prefix(2) {
                guard let image = await ThumbCache.shared.image(id, side: 512) else { continue }
                let made = await Task.detached(priority: .utility) { OwnPhotos.vector(of: image) }.value
                if let made { new.append(PhotoPrint(photoID: id, placeKey: key, packed: pack(made))) }
            }
        }
        s.prints = adding(new, to: s.prints)
        s.tried = Array(triedList.suffix(4000))
        saved = s
    }

    /// 見比べ用: そのお店で前に撮った写真（新しい食事から 2 枚まで。いまの食事の写真は除く）
    @MainActor
    static func photoIDs(of place: Place, except: Set<String>, limit: Int = 2) -> [String] {
        var out: [String] = []
        for meal in place.visibleMeals {
            guard let id = meal.photoIDs.first, !except.contains(id) else { continue }
            out.append(id)
            if out.count >= limit { break }
        }
        return out
    }
}
