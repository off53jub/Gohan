import Foundation
import SwiftData

// あとで分かったお店で、同じ場所の「迷い」を埋める（2026-11-26 案2）。
// 看板が読めた・本人が選んだ、などでお店がはっきりしたとき、同じ場所（50m 以内）で撮った昔の食事のうち、
// お店が決まっていない・自信の低いものに、同じお店を入れる。入れたものは「たぶん」のままにする（直さなくても困らない）。
// 本人が決めた食事・自信のある食事には触らない。料理のジャンルが同じ食事にだけ入れる
// （フードコートや飲食店ビルでは、50m の中に何軒もある。ジャンルの分からない食事・なかまのジャンルというだけの食事には入れない）。
// 「同じお店に間違えていた食事をまとめて直す」（お店を選び直したときに聞く。便52）は、前からある。
enum RetroFix {
    /// 同じ場所とみなす距離（m。仮）
    static let reach = 50.0
    /// この自信より上で決まったお店だけ、ほかの食事に広げる
    static let sureLine = 0.8
    /// 埋めた食事の自信（「たぶん」の線 0.7 より下にしておく）
    static let filledConfidence = 0.65
    static let reasonText = "同じ場所の別の日に、お店が分かりました"
    /// 近くに同じジャンルの別のお店があるかを見る範囲（m）
    static let crowdReach = 100.0

    /// 埋めるかどうかを見る食事（テストできるように、要るものだけ抜き出す）
    struct Other {
        var hasPlace: Bool
        var confidence: Double
        var genre: String
        var eatenOut: Bool = true
        var hidden: Bool = false
        /// おうち・職場の食事
        var atHomeOrWork: Bool = false
        /// お店が分かった食事との距離（どちらかに位置が無ければ nil）
        var distance: Double?
    }

    /// sureGenre: お店が分かった食事のジャンル。shopGenre: お店の名前・種類から分かるジャンル
    static func shouldFill(_ other: Other, sureGenre: String, shopGenre: String?) -> Bool {
        guard !other.hidden, other.eatenOut, !other.atHomeOrWork, let d = other.distance, d <= reach else { return false }
        // お店が入っている食事は、迷っているものだけ。入っていない食事も、本人が決めたもの（自信 1）は触らない
        guard other.confidence < (other.hasPlace ? 0.6 : 1) else { return false }
        // ジャンルの分からない食事には入れない（近くの別のお店かもしれない）
        guard other.genre != "その他" else { return false }
        func fits(_ genre: String?) -> Bool {
            guard let genre else { return false }
            return genre == other.genre || sameKind.contains { $0.contains(genre) && $0.contains(other.genre) }
        }
        return fits(sureGenre) || fits(shopGenre)
    }

    /// 近くに、同じジャンルの別のお店があるか（2026-11-27）。あれば、どのお店か取り違えやすいので埋めない。
    /// 当たり具合の記録で、西新宿で「春日亭」を 50m 以内の 4 食に入れ、3 食が別のラーメン屋（一蘭・中華そば 流川 など）だった。
    /// nearby はお店が分かった食事と、埋めようとする食事の候補（crowdReach 以内）。候補が 1 つも無ければ、分からないので「多い」とみなす。
    /// 種類のはっきり違うお店（カフェ・バーなど）だけなら、埋める
    static func crowded(_ nearby: [PlaceCandidate], shop: String, genre: String, shopGenre: String?) -> Bool {
        guard !nearby.isEmpty else { return true }
        let me = Matcher.normalize(shop)
        return nearby.contains { c in
            guard Matcher.normalize(c.name) != me else { return false }
            // 種類の分からないお店（地図の名前だけのラーメン屋など）も、同じジャンルかもしれないので「多い」に数える
            guard let g = Matcher.candidateGenre(c) else { return true }
            return [genre, shopGenre].contains { want in
                guard let want else { return false }
                return g == want || sameKind.contains { $0.contains(g) && $0.contains(want) }
            }
        }
    }

    /// 同じお店で出るのがふつうの、ごく近いジャンルの組（和食どうし・洋食どうし のような広いなかまは入れない）
    static let sameKind: [Set<String>] = [["ラーメン", "つけ麺"], ["カフェ", "スイーツ"]]

    /// 元に戻すための覚え
    struct Change {
        var meal: Meal
        var place: Place?
        var confidence: Double
        var needsCheck: Bool
        var reason: String
        var source: String
    }

    /// meal のお店を、同じ場所の迷っている食事に入れる。変えた食事（元の状態つき）を返す
    @MainActor
    @discardableResult
    static func fill(from meal: Meal, context: ModelContext) -> [Change] {
        guard AISettings.retroFix, !EvalMode.on, let place = meal.place, !meal.hidden, meal.eatenOut,
              let lat = meal.latitude, let lon = meal.longitude else { return [] }
        let name = Matcher.normalize(place.name)
        let shopGenre = Matcher.candidateGenre(place.candidate)
        let around = meal.candidates.filter { $0.distance <= crowdReach }
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden && $0.eatenOut })
        var changes: [Change] = []
        for other in (try? context.fetch(descriptor)) ?? [] where other.id != meal.id && other.place !== place {
            guard let a = other.latitude, let b = other.longitude else { continue }
            let input = Other(hasPlace: other.place != nil, confidence: other.confidence, genre: other.genre,
                              atHomeOrWork: !other.spot.isEmpty, distance: Matcher.distance(lat, lon, a, b))
            guard shouldFill(input, sureGenre: meal.genre, shopGenre: shopGenre) else { continue }
            // お店の多い所（近くに同じジャンルの別のお店がある）では埋めない
            let nearby = around + other.candidates.filter { $0.distance <= crowdReach }
            if crowded(nearby, shop: place.name, genre: other.genre, shopGenre: shopGenre) { continue }
            // その場所で「このお店ではない」と直されていたら入れない
            if Corrections.lookup(latitude: a, longitude: b).wrong.contains(name) { continue }
            changes.append(Change(meal: other, place: other.place, confidence: other.confidence, needsCheck: other.needsCheck,
                                  reason: other.reason, source: other.source))
            other.place = place
            other.confidence = filledConfidence
            other.needsCheck = true
            other.reason = reasonText
            if !other.source.contains("+retro") { other.source += "+retro" }
            OwnPhotos.move(photoIDs: other.photoIDs, to: place.key)
            Metrics.count("retroFills")
        }
        return changes
    }

    /// 元に戻す
    @MainActor
    static func undo(_ changes: [Change]) {
        for change in changes {
            change.meal.place = change.place
            change.meal.confidence = change.confidence
            change.meal.needsCheck = change.needsCheck
            change.meal.reason = change.reason
            change.meal.source = change.source
        }
    }
}
