import BackgroundTasks
import Foundation
import Observation
import Photos
import SwiftData
import UIKit

/// 見た写真の覚え（写真アプリの ID → 端末で見た結果）。食べ物でない写真も覚えておく（看板・メニューの手がかりに使う）
enum SeenStore {
    private static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("seen-photos.json")
    }

    static func load() -> [String: SeenPhoto] {
        // 自分で保存したファイル
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SeenPhoto].self, from: data)) ?? [:]
    }

    static func save(_ seen: [String: SeenPhoto]) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(seen) { try? data.write(to: url, options: .atomic) }
    }

    static func reset() { try? FileManager.default.removeItem(at: url) }
}

/// 写真を読んで、食事の記録を作る
@MainActor
@Observable
final class Scanner {
    static let shared = Scanner()
    nonisolated static let taskID = "com.off53jub.gohan.scan"
    nonisolated static let refreshID = "com.off53jub.gohan.refresh"
    nonisolated static let backfillID = "com.off53jub.gohan.backfill"

    enum Mode { case normal, quick, backfill }

    var isRunning = false
    var status = ""
    var lastError: String?
    var lastRun: Date?
    /// この読み込みで見つけた食事の数（はじめの画面で見せる）
    var found = 0
    /// 新しく作った食事の写真（はじめの画面で、1枚ずつ帖に入る様子に使う）
    var recentPhotoIDs: [String] = []
    /// 充電・Wi-Fi を待っている古い写真の数（便6）
    var deferredOld = 0
    @ObservationIgnored var container: ModelContainer?
    @ObservationIgnored private(set) var dishBook: [String: String] = [:]

    /// 料理の名前のそろえ方を、いまの記録から作り直す（PC から取り込むときにも使う）
    func refreshDishBook(_ meals: [Meal]) { dishBook = Matcher.dishBook(meals.map(\.dishes)) }

    /// 新しい写真を読む。作った食事の数を返す
    @discardableResult
    func scan(mode: Mode = .normal, notify: Bool = false) async -> Int {
        guard let container, !isRunning else { return 0 }
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            lastError = "写真を見る許可がありません（設定アプリ → ごはん帖 → 写真）"
            return 0
        }
        isRunning = true
        lastError = nil
        found = 0
        defer {
            isRunning = false
            status = ""
            lastRun = Date()
        }
        let context = container.mainContext
        let allMeals = (try? context.fetch(FetchDescriptor<Meal>())) ?? []
        fixOldGenres(allMeals)
        dishBook = Matcher.dishBook(allMeals.map(\.dishes))

        var seen = SeenStore.load()
        let cutoff = Date().addingTimeInterval(-Matcher.holdBack)
        var fresh = newAssets(since: ScanSettings.since, before: cutoff, seen: seen)

        // 古い写真が多いときは、充電中で Wi-Fi のときにまとめて読む（便6）
        let recentLine = Date().addingTimeInterval(-7 * 86_400)
        let old = fresh.filter { ($0.creationDate ?? Date()) < recentLine }
        if mode != .backfill, !Backfill.allowed, old.count > 150 {
            let keepOld = Set(old.prefix(mode == .quick ? 0 : 150).map(\.localIdentifier))
            fresh = fresh.filter { ($0.creationDate ?? Date()) >= recentLine || keepOld.contains($0.localIdentifier) }
            deferredOld = old.count - keepOld.count
            Self.scheduleBackfill()
        } else {
            deferredOld = 0
        }

        // 1. どの写真が食べ物か（端末の中だけで見る）
        for (i, asset) in fresh.enumerated() {
            if Task.isCancelled { break }
            status = "写真を見ています \(i + 1)/\(fresh.count)"
            seen[asset.localIdentifier] = await look(asset)
            if i % 40 == 39 { SeenStore.save(seen) }
        }
        SeenStore.save(seen)

        // 2. 食べ物の写真を食事にまとめ、お店と料理を決める
        let all = Array(seen.values)
        let pending = all.filter { $0.food >= Matcher.foodThreshold && !$0.used && $0.date < cutoff && !$0.noCamera }
        // iPhone の訪問の記録（どこに何分いたか）があれば、食事の区切りにも使う（2026-11-26 案4）
        let visits = ScanSettings.visitGroups ? VisitLog.load() : []
        let groups = Matcher.groupMeals(Matcher.fillLocations(pending, among: all), visits: visits)
        var added: [Meal] = []
        for (i, group) in groups.enumerated() {
            if Task.isCancelled { break }
            status = "お店を調べています \(i + 1)/\(groups.count)"
            if appendToRecentMeal(group, visits: visits, context: context) == false {
                let isOld = (group.first?.date ?? Date()) < Date().addingTimeInterval(-2 * 86_400)
                if let meal = await buildMeal(group, all: all, context: context, old: isOld) {
                    added.append(meal)
                    found += 1
                    recentPhotoIDs = Array(([meal.photoIDs.first].compactMap { $0 } + recentPhotoIDs).prefix(12))
                }
            }
            for photo in group { seen[photo.id]?.used = true }
            SeenStore.save(seen)
            try? context.save()
        }

        // 3. あとで AI に見てもらう分（圏外だった・まとめ処理）
        await retryPending(context: context)
        await runBatches(context: context)

        // 3.5 大型アップデート（2026-11-28）: お店が空の昔の食事を種類で探し直す・くせを数え直す・月のはじめの知らせ
        await RetroSearch.run(context: context)
        Habits.refresh(context: context)
        MonthlyNote.sendIfDue(context: context)

        // 4. 後片づけ（検索・バックアップ・閉店チェック・近くに来たら）
        Spotlight.index(added)
        for meal in added { Backup.fillCloudIDs(meal) }
        try? context.save()
        Backup.autoWrite(context: context)
        await checkClosed(context: context)
        // Google から取ったお店を、保存してよい取り元で見つけ直す（Google の決まり。2026-11-26）
        await PlaceRehome.sweep(context: context)
        // お店の決まった食事の写真の「見た目の印」を、少しずつ作りためる（自分の過去の写真と見比べるため。2026-11-26 案1）
        await OwnPhotos.backfill(context: context)
        // PC から前に取り込んだ写真を、少しずつ小さく置き直す（端末の空きを食わないように。2026-11-27）
        await ImportedPhotos.shrinkSome()
        await refreshFences(context: context)

        if notify, let meal = added.last {
            let thumb = await ThumbCache.shared.image(meal.photoIDs.first ?? "", side: 600)
            Notifier.tellMeal(title: meal.title, dishes: meal.dishText, mealID: meal.id, thumbnail: thumb?.jpegData(compressionQuality: 0.7))
        }
        if !ScanSettings.initialDone, deferredOld == 0 {
            ScanSettings.initialDone = true
            if UIApplication.shared.applicationState != .active {
                let total = (try? context.fetchCount(FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden }))) ?? added.count
                Notifier.tellInitialDone(total)
            }
        }
        return added.count
    }

    /// 前の版で、端末だけで決めたジャンル（ラーメンが「スープ」「パスタ」など）を、お店の名前から1回だけ直す。
    /// 本人が直したもの（ジャンルが写真の判定と違うもの）は触らない（2026-11-24）
    private func fixOldGenres(_ meals: [Meal]) {
        guard !UserDefaults.standard.bool(forKey: "fix.genre.v1") else { return }
        UserDefaults.standard.set(true, forKey: "fix.genre.v1")
        for meal in meals where meal.source == "device" || meal.source == "known" {
            guard let mapped = Matcher.dishNames[meal.visionLabel], meal.genre == mapped.genre || meal.genre == "その他" else { continue }
            guard let place = meal.place, let g = Matcher.genre(fromText: place.name), g != meal.genre else { continue }
            meal.genre = g
            if meal.dishes == [mapped.dish] { meal.dishes = g == "ラーメン" ? ["ラーメン"] : [] }
        }
    }

    /// 写真1枚を端末の中で見る
    private func look(_ asset: PHAsset) async -> SeenPhoto {
        let isVideo = asset.mediaType == .video
        var result = PhotoVision.Look(food: 0, label: "")
        let image: UIImage?
        if isVideo {
            image = await PhotoLoader.videoFrame(asset, side: 360)
        } else {
            image = await PhotoLoader.image(asset, side: 360)
        }
        if let image {
            result = await Task.detached(priority: .utility) { PhotoVision.look(image) }.value
        }
        var noCamera = false
        // 場所が無い食べ物の写真は、カメラで撮ったものか確かめる（SNS から保存した画像を除く。便22）
        if !isVideo, asset.location == nil, result.food >= Matcher.foodThreshold {
            let camera = await PhotoLoader.isCameraPhoto(asset)
            noCamera = !camera
        }
        let location = asset.location
        // 高さ（何階かの手がかり。案9）。0 ちょうどは「書いてない」ことが多いので使わない
        let altitude = location.flatMap { $0.altitude != 0 ? $0.altitude : nil }
        let altitudeAccuracy = location.flatMap { $0.verticalAccuracy > 0 ? $0.verticalAccuracy : nil }
        return SeenPhoto(
            id: asset.localIdentifier,
            date: asset.creationDate ?? Date(),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            accuracy: location?.horizontalAccuracy,
            food: result.food,
            label: result.label,
            isVideo: isVideo,
            noCamera: noCamera,
            labels: result.labels,
            altitude: altitude,
            altitudeAccuracy: altitudeAccuracy
        )
    }

    private func newAssets(since: Date, before: Date, seen: [String: SeenPhoto]) -> [PHAsset] {
        let options = PHFetchOptions()
        if ScanSettings.videos {
            options.predicate = NSPredicate(format: "(mediaType == %d OR (mediaType == %d AND duration < 60)) AND creationDate > %@ AND creationDate < %@",
                                            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue, since as NSDate, before as NSDate)
        } else {
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate > %@ AND creationDate < %@",
                                            PHAssetMediaType.image.rawValue, since as NSDate, before as NSDate)
        }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            guard seen[asset.localIdentifier] == nil, !asset.mediaSubtypes.contains(.photoScreenshot),
                  asset.sourceType != .typeCloudShared else { return }
            out.append(asset)
        }
        return out
    }

    /// 前の読み込みで作った食事の続き（同じお店で、あとから撮った写真）なら、そこに足す
    private func appendToRecentMeal(_ group: [SeenPhoto], visits: [Visit] = [], context: ModelContext) -> Bool {
        guard let first = group.first, let last = group.last else { return true }
        let from = first.date.addingTimeInterval(-Matcher.stayMealGap)
        let to = first.date
        let shortFrom = first.date.addingTimeInterval(-Matcher.mealGap)
        let longFrom = first.date.addingTimeInterval(-Matcher.longMealGap)
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.endDate >= from && $0.endDate <= to })
        guard let meals = try? context.fetch(descriptor) else { return false }
        let spot = Matcher.center(of: group)
        for meal in meals where !meal.hidden {
            // 訪問の記録で、別の所へ移ったと分かるときはつながない（はしご。案4）
            let link = VisitLog.link(visits, meal.endDate, first.date)
            if link == .moved { continue }
            if let spot, let lat = meal.latitude, let lon = meal.longitude,
               Matcher.distance(lat, lon, spot.latitude, spot.longitude) > Matcher.mealDistance { continue }
            // 40 分より前に終わった食事は、同じ所にいたと分かるときだけつなぐ（飲み会・コース）:
            // 訪問の記録で同じ滞在なら 150 分まで、写真の位置が 100m 以内なら 90 分まで
            if meal.endDate < shortFrom, link != .sameStay {
                guard meal.endDate >= longFrom, let spot, let lat = meal.latitude, let lon = meal.longitude,
                      Matcher.distance(lat, lon, spot.latitude, spot.longitude) <= Matcher.sameSpotDistance else { continue }
            }
            meal.photoIDs.append(contentsOf: group.map(\.id).filter { !meal.photoIDs.contains($0) })
            meal.endDate = max(meal.endDate, last.date)
            return true
        }
        return false
    }

    /// 1回の食事を作る。作ったら返す（食事でないと分かったときは、消した扱いで残して nil）
    /// preset は PC で決めてきた答え（あればこのアプリの AI・Google は呼ばない。PC から取り込む）
    func buildMeal(_ group: [SeenPhoto], all: [SeenPhoto], context: ModelContext, old: Bool,
                   preset: MealVerdict? = nil, presetLines: [String] = [], presetPlace: ImportPlace? = nil) async -> Meal? {
        guard let first = group.first, let last = group.last else { return nil }
        var spot = Matcher.center(of: group)
        // 1. iPhone の訪問の記録（どこに何分いたか）。写真に位置が無い・ビルの中で位置があいまいなときは、こちらの位置を使う
        let photoAccuracy = group.compactMap(\.accuracy).filter { $0 > 0 }.min()
        let visit = VisitLog.match(VisitLog.load(), from: first.date, to: last.date)
        var usedVisit = false
        if let visit, Matcher.useVisit(visit, spot: spot, accuracy: photoAccuracy) {
            spot = (latitude: visit.latitude, longitude: visit.longitude)
            usedVisit = true
        }
        let stay = visit?.minutes.flatMap { $0 > 0 && $0 < 600 ? $0 : nil }
        // 料理の写真のあとに、食事中に同じ場所で撮ったほかの写真（人・お店の中）も入れる。表紙は料理のまま（2026-11-25）
        let companions = ScanSettings.companions ? Matcher.companionPhotos(for: group, among: all).map(\.id) : []
        let meal = Meal(date: first.date, endDate: last.date, photoIDs: group.map(\.id) + companions,
                        latitude: spot?.latitude, longitude: spot?.longitude)
        let label = group.max { $0.food < $1.food }?.label ?? ""
        meal.visionLabel = label
        if let anniversary = Anniversary.on(first.date) { meal.special = true; meal.note = anniversary.name }

        // おうち・職場なら、お店は探さない（便14・便15）
        if let spot { meal.spot = Spots.which(latitude: spot.latitude, longitude: spot.longitude) }
        if let spot {
            let place = await PlaceFinder.areaAndRegion(latitude: spot.latitude, longitude: spot.longitude)
            meal.area = place.area
            meal.region = place.region
        }

        // 料理の写真（多ければ散らして3枚）と、前後の手がかりの写真
        var lines: [String] = presetLines
        var foodJPEGs: [Data] = []
        // 料理の写真は 4 枚まで AI に見せる（3 枚だと、ラーメンと丼・つけ麺とそばの見分けに足りないことがあった。2026-11-25）
        // 案1: 料理の写真の「見た目の印」（端末の中で作る。前に行ったお店の写真と比べる）
        var foodPrints: [(photoID: String, vector: [Float])] = []
        // 案3: 小さな字のある所（あとで元の細かさから切り出す）
        var foodText: [(id: String, boxes: [CGRect], size: CGSize)] = []
        for photo in Self.spread(group.sorted { $0.food > $1.food }, count: 4) {
            guard let image = await loadImage(photo, side: 1024) else { continue }
            let found = await Task.detached(priority: .utility) { PhotoVision.textBoxes(image) }.value
            lines += found.map(\.text)
            if found.count >= 2 { foodText.append((photo.id, found.map(\.box), image.size)) }
            if AISettings.ownPhotos, preset == nil,
               let made = await Task.detached(priority: .utility, operation: { OwnPhotos.vector(of: image) }).value {
                foodPrints.append((photo.id, made))
            }
            if let data = await sendable(image) { foodJPEGs.append(data) }
        }
        var clueShots: [(id: String, data: Data, count: Int)] = []
        var zoomJPEGs: [Data] = []
        // 案9: 看板・外観の写真を撮ったときの、カメラの向き
        var shots: [Matcher.Shot] = []
        let nearby = Matcher.cluePhotos(for: group, among: all)
        for photo in nearby {
            guard let asset = PhotoLoader.asset(photo.id) else { continue }
            if AISettings.direction, let lat = photo.latitude, let lon = photo.longitude, (photo.accuracy ?? 100) <= 35,
               let heading = await PhotoLoader.direction(asset) {
                shots.append(Matcher.Shot(latitude: lat, longitude: lon, heading: heading))
            }
            guard let image = await PhotoLoader.image(asset, side: 1024) else { continue }
            let found = await Task.detached(priority: .utility) { PhotoVision.textBoxes(image) }.value
            guard !found.isEmpty else { continue }
            lines += found.map(\.text)
            if let data = await sendable(image) { clueShots.append((photo.id, data, found.count)) }
            if AISettings.zoomText, zoomJPEGs.count < 2,
               let cut = await zoom(asset: asset, boxes: found.map(\.box), size: image.size) {
                let fresh = cut.lines.filter { !lines.contains($0) }
                lines += fresh
                zoomJPEGs.append(cut.data)
            }
        }
        // 料理の写真に小さな字（メニュー・箸袋など）が写っているときも、1 枚だけ切り出す
        if AISettings.zoomText, zoomJPEGs.count < 2, let best = foodText.max(by: { $0.boxes.count < $1.boxes.count }),
           let asset = PhotoLoader.asset(best.id), let cut = await zoom(asset: asset, boxes: best.boxes, size: best.size) {
            let fresh = cut.lines.filter { !lines.contains($0) }
            lines += fresh
            zoomJPEGs.append(cut.data)
        }
        let topClues = clueShots.sorted { $0.count > $1.count }.prefix(2)
        meal.cluePhotoIDs = topClues.map(\.id)
        let clueJPEGs = topClues.map(\.data)
        // 案9: 料理の写真と、外で撮った写真の高さのちがい（確かなときだけ）
        var hints: [String] = []
        if AISettings.direction, let floorNote = Matcher.floorHint(food: group, outside: nearby) { hints.append(floorNote) }
        let receipt = Matcher.receiptNames(lines)
        let event = CalendarClue.event(around: first.date)

        // 写真のジャンル（写真の上位の名前・看板やメニューの文字・本人が直したジャンル。2026-11-24）
        let labels = Matcher.mergeLabels(group)
        var photoGuess = Matcher.guessGenre(labels: labels, lines: lines + receipt, shopName: nil, learned: GenreLearn.lookup(label))
        if let preset, preset.genre != "その他" { photoGuess = GenreGuess(genre: preset.genre, dish: nil, from: "pc") }

        // お店の候補（近くの飲食店・写真の文字で探したお店・予定の場所・前に行ったお店）
        // 位置があいまい（ビルの中・地下・位置を借りた写真）なら、広く探して候補も多めにする（5）
        var accuracy = photoAccuracy ?? 50
        if usedVisit, let visit { accuracy = visit.accuracy }
        let indoor = accuracy > 65
        var candidates: [PlaceCandidate] = []
        if let spot, meal.spot.isEmpty {
            let radius = indoor ? 450 : min(300, max(80, accuracy * 2))
            var lists = [await PlaceFinder.nearbyAll(latitude: spot.latitude, longitude: spot.longitude, radius: radius)]
            var queries = receipt + Matcher.searchableLines(lines)
            if let event { queries.append(event) }
            // PC から取り込むときは名前で探さない（何千食も続けて調べるので、地図の検索の上限に当たらないように。
            // PC で選んだお店・写真から読んだ店名は、あとで 1 回だけ探す）
            for query in queries.prefix(preset == nil ? 5 : 0) {
                lists.append(await PlaceFinder.searchAll(query, latitude: spot.latitude, longitude: spot.longitude, radius: 700))
            }
            lists.append(PlaceBook.visited(near: spot.latitude, spot.longitude, context: context))
            candidates = PlaceFinder.merge(lists)
        }
        // 案1: 前に行ったお店で撮った写真と似ていれば、そのお店を候補に入れる（場所の無い写真でも）。
        // 場所が分かっているときは、400m より遠いお店は入れない（同じチェーンの別のお店などを除く）
        var alikePlaces: [Place] = []
        if meal.spot.isEmpty, !foodPrints.isEmpty {
            let found = OwnPhotos.hints(OwnPhotos.matches(foodPrints.map(\.vector), known: OwnPhotos.all, skip: Set(meal.photoIDs)))
            for match in found {
                guard let place = PlaceBook.find(key: match.placeKey, context: context) else { continue }
                var c = place.candidate
                if let spot {
                    c.distance = Matcher.distance(spot.latitude, spot.longitude, place.latitude, place.longitude)
                    if c.distance > 400 { continue }
                } else {
                    // 場所が無いときは、端末の点数だけでは選ばれないようにしておく（似ているだけでは決めない）
                    c.distance = PlaceCandidate.unknownDistance
                    c.visited = false
                }
                c.alike = true
                c.note = ShopMenu.note(place.menuNames)
                candidates = PlaceFinder.merge([candidates, [c]])
                alikePlaces.append(place)
            }
            if !alikePlaces.isEmpty { Metrics.count("ownPhotoHints") }
        }
        var ranked = Matcher.rank(candidates, lines: lines + receipt, dishLabel: label)
        // 2. 撮った時刻に閉まっていたはずのお店は下げる
        ranked = Matcher.applyHours(Habits.apply(Matcher.applyGenre(ranked, photoGenre: photoGuess?.genre),
                                                 photoGenre: photoGuess?.genre, habit: Habits.topGenre), at: first.date)
        // 案1・案9: 写真が似ているお店・看板の写真が向いていた先のお店を、少し上へ
        ranked = Matcher.applyDirection(Matcher.applyAlike(ranked), shots: shots)
        ranked = Array(ranked.prefix(indoor ? 20 : 12))
        if let spot {
            let learned = Corrections.lookup(latitude: spot.latitude, longitude: spot.longitude)
            ranked = Matcher.applyCorrections(ranked, right: learned.right, wrong: learned.wrong)
        }
        meal.candidates = ranked

        // 決め方を選ぶ
        let ready = preset == nil && ClaudeLink.isReady && Spend.canSpend && !foodJPEGs.isEmpty
        let known = meal.spot.isEmpty && spot != nil ? Matcher.knownPlace(ranked) : nil
        var verdict: MealVerdict?
        var askedPrompt: String?
        // 案3: 大きく切り出した絵は、お店がもうはっきりしているとき（前に行ったお店・看板が読めた）は送らない
        let sentClues = Array(clueJPEGs) + (known == nil && !Matcher.isEasy(ranked) ? zoomJPEGs : [])
        let zoomCount = sentClues.count - clueJPEGs.count
        if var preset {
            // PC で決めてきた料理・ジャンル。お店は PC の答えが候補にあればそれ、無ければ端末の点数で選ぶ
            var (pick, confidence) = Matcher.decideOnDevice(ranked)
            confidence = min(0.65, confidence)
            if pick.map({ $0.score < 0.25 }) ?? true { pick = nil }
            preset.reason = ""
            if let wanted = presetPlace, wanted.confidence >= 0.4, !wanted.name.isEmpty {
                let core = Matcher.coreName(wanted.name)
                if let named = ranked.first(where: { Matcher.similarity(Matcher.coreName($0.name), core) >= 0.6 }) {
                    pick = named
                    confidence = min(0.9, max(confidence, wanted.confidence))
                    preset.reason = wanted.reason
                }
            }
            if let pick, let index = ranked.firstIndex(of: pick) {
                preset.place_index = index
                preset.place_confidence = confidence
            } else {
                preset.place_index = -1
                preset.place_confidence = 0
            }
            verdict = preset
            meal.source = "pc"
        } else if ready {
            let light = AISettings.lightForEasy && (known != nil || !meal.spot.isEmpty || Matcher.isEasy(ranked))
            // 前に行ったお店なら、前に調べた料理名もそえる（案10）
            let knownText = known.map { "\($0.name)（\($0.address)）" + ($0.note.isEmpty ? "" : " ／\($0.note)") }
            let prompt = ClaudeVision.prompt(date: first.date, area: meal.area, candidates: known.map { [$0] } ?? ranked, lines: lines,
                                             foodCount: foodJPEGs.count, clueCount: clueJPEGs.count, event: event, receipt: receipt,
                                             knownPlace: knownText, indoor: indoor, stay: stay,
                                             zoomCount: zoomCount, hints: hints, located: spot != nil)
            askedPrompt = prompt
            if old, AISettings.batchOld, known == nil, meal.spot.isEmpty {
                // 古い写真は急がないので、まとめ処理で半額に（便13）。答えが来るまでは端末で決めておく
                BatchQueue.enqueue(mealID: meal.id, body: ClaudeVision.body(food: foodJPEGs, clues: sentClues, prompt: prompt, light: false))
                meal.aiPending = true
                meal.source = "batch"
            } else {
                do {
                    verdict = try await ClaudeVision.judge(food: foodJPEGs, clues: sentClues, prompt: prompt, light: light)
                    meal.source = light ? "claude-light" : "claude"
                } catch ClaudeError.offline {
                    meal.aiPending = true
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
        if let known, verdict == nil || verdict?.eaten_out == true {
            // 前に行ったお店は、AI に聞かなくても決める（便11）
            apply(verdict, to: meal, ranked: [known], forcedPick: known, context: context, labels: labels, lines: lines + receipt)
            if verdict == nil { meal.source = "known" }
        } else {
            apply(verdict, to: meal, ranked: ranked, forcedPick: nil, context: context, labels: labels, lines: lines + receipt)
            // 迷ったときだけ、いちばん強いモデルに同じ写真と候補で聞き直す（本人「迷ったときだけ上のモデル」2026-11-26）
            if let prompt = askedPrompt, verdict != nil, meal.source.hasPrefix("claude"), meal.eatenOut, !meal.hidden,
               meal.confidence < 0.6, AISettings.escalate, ClaudeLink.isReady, Spend.canSpend {
                status = "よく見直しています"
                if let second = try? await ClaudeVision.judgeStrong(food: foodJPEGs, clues: sentClues, prompt: prompt) {
                    Metrics.count("escalations")
                    let before = meal.confidence
                    if second.is_meal, second.place_index >= 0, second.place_confidence > before {
                        apply(second, to: meal, ranked: ranked, forcedPick: nil, context: context, labels: labels, lines: lines + receipt)
                        verdict = second
                        meal.source += "+strong"
                    } else if second.is_meal, !meal.genreByHand {
                        // お店は決まらなくても、料理とジャンルは強いモデルの答えにする
                        meal.genre = Matcher.consistentGenre(second.genre, dishes: second.dishes, shop: nil, shopConfidence: 0)
                        meal.dishes = Matcher.canonicalDishes(second.dishes.filter { !$0.isEmpty }, book: dishBook)
                        meal.summary = second.summary
                        if !second.name_seen.isEmpty { verdict = second }
                    }
                }
            }
        }

        if let spot, meal.eatenOut, meal.spot.isEmpty, known == nil, !meal.hidden {
            // 2. AI が写真から読んだ店名で、地図を探し直す（候補に無かったとき・選んだお店と名前が合わないとき）
            if let seen = verdict?.name_seen, !seen.isEmpty,
               let found = await research(name: seen, current: meal.place, latitude: spot.latitude, longitude: spot.longitude) {
                setPlace(found, on: meal, confidence: 0.75, reason: "写真の店名「\(seen)」で探し直しました", context: context)
                meal.source += "+name"
            }
            // PC で選んできたお店が、まだ決まったお店と違うとき（候補に無かった）。名前で探し、無ければ OpenStreetMap の場所のまま置く
            if let wanted = presetPlace, wanted.confidence >= 0.4, !wanted.name.isEmpty,
               Matcher.similarity(Matcher.coreName(meal.place?.name ?? ""), Matcher.coreName(wanted.name)) < 0.6 {
                let lat = wanted.latitude ?? spot.latitude
                let lon = wanted.longitude ?? spot.longitude
                let why = wanted.reason.isEmpty ? "PC で場所と写真から選びました" : wanted.reason
                if let found = await research(name: wanted.name, current: meal.place, latitude: lat, longitude: lon, radius: 500) {
                    setPlace(found, on: meal, confidence: min(0.85, wanted.confidence), reason: why, context: context)
                } else if let la = wanted.latitude, let lo = wanted.longitude {
                    let osm = PlaceCandidate(name: wanted.name, address: meal.area, category: "osm", latitude: la, longitude: lo,
                                             distance: Matcher.distance(spot.latitude, spot.longitude, la, lo))
                    setPlace(osm, on: meal, confidence: min(0.8, wanted.confidence), reason: why, context: context)
                }
                meal.source += "+place"
            }
            // 案5: 料理の種類は分かったのに、その種類のお店が候補に 1 軒も無いとき、種類の名前で近くを探し直す
            // （Apple のマップとホットペッパー。無料）。見つかったら、増えた候補で AI にもう一度選んでもらう
            if preset == nil, AISettings.genreSearch, meal.place == nil || meal.confidence < 0.6, !meal.aiPending,
               let word = Matcher.genreSearchWord(meal.genre, dishes: meal.dishes), Matcher.lacksGenre(ranked, genre: meal.genre) {
                status = "「\(word)」のお店を探しています"
                let found = await PlaceFinder.searchAll(word, latitude: spot.latitude, longitude: spot.longitude, radius: indoor ? 450 : 300)
                let already = Set(ranked.map { Matcher.normalize($0.name) })
                let fresh = found.filter { !already.contains(Matcher.normalize($0.name)) }.map { c -> PlaceCandidate in
                    var c = c
                    // 名前や種類からジャンルが分からないお店には、どう探して見つけたかをそえる
                    if Matcher.candidateGenre(c) == nil, c.note.isEmpty { c.note = "「\(word)」で探して見つかったお店" }
                    return c
                }
                if !fresh.isEmpty {
                    Metrics.count("genreSearches")
                    let merged = remerge(ranked, fresh: fresh, lines: lines + receipt, label: label, genre: meal.genre,
                                         date: first.date, indoor: indoor, spot: spot)
                    meal.candidates = merged
                    if ClaudeLink.isReady, Spend.canSpend, !foodJPEGs.isEmpty {
                        let again = ClaudeVision.prompt(date: first.date, area: meal.area, candidates: merged, lines: lines,
                                                        foodCount: foodJPEGs.count, clueCount: clueJPEGs.count, event: event,
                                                        receipt: receipt, indoor: indoor, stay: stay, zoomCount: zoomCount, hints: hints)
                        if let second = try? await ClaudeVision.judge(food: foodJPEGs, clues: sentClues, prompt: again),
                           second.place_index >= 0, second.place_index < merged.count, second.place_confidence > meal.confidence {
                            setPlace(merged[second.place_index], on: meal, confidence: second.place_confidence,
                                     reason: second.reason.isEmpty ? "「\(word)」で近くを探し直して選びました" : second.reason, context: context)
                        }
                    } else {
                        let (pick, confidence) = Matcher.decideOnDevice(merged)
                        if let pick, pick.score >= 0.25, confidence > meal.confidence {
                            setPlace(pick, on: meal, confidence: confidence, reason: Matcher.reason(for: pick, source: "device", receipt: false), context: context)
                        }
                    }
                    ranked = merged
                    meal.source += "+genre"
                }
            }
            // Apple・ホットペッパーで見つからない（お店が決まらない・自信が低い）ときだけ、Google でも探す（本人の希望。2026-11-24）
            // PC から入れた食事では呼ばない（何千食もあるので。Google は使いすぎると料金がかかる。必要なら「お店を選ぶ」で自分で探す。2026-11-25）
            // 2026-11-26: OpenStreetMap（無料）と Foursquare（月の上限つき）も、迷ったときに足す
            if preset == nil, meal.place == nil || meal.confidence < 0.6, !meal.aiPending {
                status = "ほかの地図でも探しています"
                let near = indoor ? 450.0 : 250.0
                async let osm = OSMPlaces.nearby(latitude: spot.latitude, longitude: spot.longitude, radius: near)
                async let fsq = FoursquarePlaces.nearby(latitude: spot.latitude, longitude: spot.longitude, radius: near)
                var extra: [PlaceCandidate] = []
                if KeyStore.googleKey != nil {
                    if let seen = verdict?.name_seen, !seen.isEmpty {
                        extra += await GooglePlaces.text(seen, latitude: spot.latitude, longitude: spot.longitude, radius: 1000)
                    }
                    extra += await GooglePlaces.nearby(latitude: spot.latitude, longitude: spot.longitude, radius: near)
                }
                extra += await osm
                extra += await fsq
                let already = Set(ranked.map { Matcher.normalize($0.name) })
                let fresh = PlaceFinder.merge([extra]).filter { !already.contains(Matcher.normalize($0.name)) }
                if !fresh.isEmpty {
                    let merged = remerge(ranked, fresh: fresh, lines: lines + receipt, label: label, genre: photoGuess?.genre,
                                         date: first.date, indoor: indoor, spot: spot)
                    meal.candidates = merged
                    let core = Matcher.coreName(verdict?.name_seen ?? "")
                    if !core.isEmpty, let named = fresh.first(where: { Matcher.similarity(Matcher.coreName($0.name), core) >= 0.6 }) {
                        setPlace(named, on: meal, confidence: 0.8, reason: "写真の店名「\(core)」をほかの地図で見つけました", context: context)
                    } else if preset == nil, ClaudeLink.isReady, Spend.canSpend, !foodJPEGs.isEmpty {
                        // 増えた候補で、AI にもう一度選んでもらう（PC から入れた食事では AI を呼ばない）
                        let again = ClaudeVision.prompt(date: first.date, area: meal.area, candidates: merged, lines: lines,
                                                        foodCount: foodJPEGs.count, clueCount: clueJPEGs.count, event: event,
                                                        receipt: receipt, indoor: indoor, stay: stay, zoomCount: zoomCount, hints: hints)
                        if let second = try? await ClaudeVision.judge(food: foodJPEGs, clues: sentClues, prompt: again),
                           second.place_index >= 0, second.place_index < merged.count, second.place_confidence > meal.confidence {
                            setPlace(merged[second.place_index], on: meal, confidence: second.place_confidence,
                                     reason: second.reason.isEmpty ? "Google のお店も入れて選び直しました" : second.reason, context: context)
                        }
                    } else {
                        let (pick, confidence) = Matcher.decideOnDevice(merged)
                        if let pick, pick.score >= 0.25, confidence > meal.confidence {
                            setPlace(pick, on: meal, confidence: confidence, reason: Matcher.reason(for: pick, source: "device", receipt: false), context: context)
                        }
                    }
                    meal.source += "+more"
                }
            }
            // 4a. まだ迷っていれば、料理の写真で画像検索する（似た写真がのったページの題名に、候補のお店の名前があるか）
            //     昔の写真でも動く。月の上限まで（2026-11-25）
            var webTitles: [String] = []
            if preset == nil, meal.confidence < 0.6, !meal.aiPending, ImageSearch.canUse, let photo = foodJPEGs.first {
                status = "似た写真を探しています"
                if let result = await ImageSearch.search(photo) {
                    webTitles = Array((result.titles + result.entities).prefix(8))
                    if let hit = ImageSearch.match(result, candidates: Array(meal.candidates.prefix(12))), 0.7 > meal.confidence {
                        setPlace(hit, on: meal, confidence: 0.7, reason: "似た写真がのったページにこのお店の名前がありました", context: context)
                        meal.source += "+image"
                    }
                }
            }
            // 4b. まだ迷っていれば、候補のお店の紹介写真と見比べてもらう。紹介写真の無い上位のお店は Google で写真を取ってくる
            //     （料理が写っていそうな写真を 1 軒 2 枚まで）。昔の写真でも動く。月の上限まで（2026-11-25）
            //     前に行ったお店は、この人がそこで前に撮った写真そのものと見比べる（Google は呼ばない。2026-11-26 案1）
            if preset == nil, meal.confidence < 0.6, !meal.aiPending, ClaudeLink.isReady, Spend.canSpend, !foodJPEGs.isEmpty {
                let own = await ownShopPhotos(Array(meal.candidates.prefix(8)), except: meal, context: context)
                let shops = await LookAlike.withPhotos(meal.candidates, latitude: spot.latitude, longitude: spot.longitude, own: Set(own.keys))
                if !shops.isEmpty {
                    status = "お店の写真と見比べています"
                    if let found = try? await LookAlike.ask(food: foodJPEGs, shops: shops, own: own),
                       found.answer.confidence >= 0.6, found.answer.confidence > meal.confidence {
                        let why = found.answer.reason.isEmpty ? "" : "（\(found.answer.reason)）"
                        let mine = own[found.shop.key] != nil
                        setPlace(found.shop, on: meal, confidence: min(0.8, found.answer.confidence),
                                 reason: (mine ? "前にこのお店で撮った写真と見比べました" : "お店の写真と見比べました") + why, context: context)
                        meal.source += mine ? "+ownlook" : "+look"
                    }
                }
            }
            // 4c. まだ迷っていれば、写真から読んだ料理名が、候補のお店の Google のクチコミに出てくるか（1 軒だけならそのお店。月の上限つき）
            if preset == nil, meal.confidence < 0.6, !meal.aiPending {
                let words = ReviewMatch.keywords(dishes: meal.dishes)
                if !words.isEmpty {
                    status = "クチコミと見比べています"
                    if let found = await ReviewMatch.pick(candidates: Array(meal.candidates.prefix(4)), keywords: words,
                                                          latitude: spot.latitude, longitude: spot.longitude) {
                        setPlace(found.shop, on: meal, confidence: 0.7, reason: "クチコミに「\(found.word)」がありました", context: context)
                        meal.source += "+review"
                    }
                }
            }
            // 3. まだ迷っていれば、AI にネットで確かめてもらう（新しい写真だけ・設定でオフにできる）
            if meal.confidence < 0.6, !old, AISettings.webCheck, ClaudeLink.isReady, Spend.canSpend {
                status = "ネットで確かめています"
                let hint = WebCheck.Hint(area: [meal.region, meal.area].filter { !$0.isEmpty }.joined(separator: " "),
                                         nameSeen: verdict?.name_seen ?? "", genre: meal.genre, dishes: meal.dishes,
                                         candidates: ranked.prefix(5).map(\.name), lines: Array((receipt + lines).prefix(15)) + webTitles)
                if let answer = try? await WebCheck.ask(hint), answer.confidence >= 0.5,
                   let found = await research(name: answer.name, current: meal.place, latitude: spot.latitude, longitude: spot.longitude, radius: 1500, google: true) {
                    setPlace(found, on: meal, confidence: min(0.85, answer.confidence), reason: "ネットで確かめました（\(answer.name)）", context: context)
                    meal.source += "+web"
                }
            }
        }
        // 案1: 場所の無い写真で、写真の似ているお店が候補に入ったとき。見た目の印が似ているだけでは決めない
        // （同じ種類の料理なら別のお店でも似る）。写真から店名が読めたとき、または、そのお店で前に撮った写真そのものと
        // AI が見比べて、はっきり合うと言ったときだけ決める。どちらでもなければ、お店は入れない
        if spot == nil, preset == nil, meal.spot.isEmpty, meal.eatenOut, !meal.hidden, !meal.aiPending, !alikePlaces.isEmpty {
            let pickedName = Matcher.normalize(meal.place?.name ?? "")
            var settled = !pickedName.isEmpty && ranked.contains { $0.textHit >= 0.9 && Matcher.normalize($0.name) == pickedName }
            if !settled, ClaudeLink.isReady, Spend.canSpend, !foodJPEGs.isEmpty {
                let alike = ranked.filter(\.alike)
                let own = await ownShopPhotos(alike, except: meal, context: context)
                let shops = alike.filter { own[$0.key] != nil }
                if !shops.isEmpty {
                    status = "前に撮った写真と見比べています"
                    if let found = try? await LookAlike.ask(food: foodJPEGs, shops: shops, own: own), found.answer.confidence >= 0.7 {
                        let why = found.answer.reason.isEmpty ? "" : "（\(found.answer.reason)）"
                        setPlace(found.shop, on: meal, confidence: min(0.8, found.answer.confidence),
                                 reason: "前にこのお店で撮った写真と見比べました" + why, context: context)
                        meal.source += "+ownlook"
                        settled = true
                    }
                }
            }
            if !settled, meal.place != nil {
                meal.place = nil
                meal.confidence = 0
                meal.reason = ""
                meal.needsCheck = true
            }
        }
        // どれだけ当たるかをあとで数えられるように、写真が似ていたお店に決まった食事に印を付ける
        if let place = meal.place, alikePlaces.contains(where: { $0 === place }), !meal.source.contains("+own") { meal.source += "+own" }
        // まだ迷っていれば、一緒に食べた相手（ふたり帖）の答えで補う（AI も地図も呼ばない。2026-11-26）
        PartnerStore.shared.fillFromPartner(meal, context: context)
        context.insert(meal)
        guard !meal.hidden else { return nil }
        if preset == nil, !EvalMode.on {
            // 案10: はじめてのお店は、名物を調べて料理名をお店での呼び名に合わせる
            await nameDishes(meal, photo: foodJPEGs.first, old: old)
            if let place = meal.place, meal.eatenOut, meal.confidence >= Matcher.sureLine {
                // 案1: 自信のある食事の写真の印を覚える（次からの見比べに使う）
                OwnPhotos.remember(foodPrints, placeKey: place.key)
                // 案2: お店がはっきりしたら、同じ場所の昔の迷いも埋める
                if meal.confidence >= RetroFix.sureLine { RetroFix.fill(from: meal, context: context) }
            }
        }
        return meal
    }

    /// 増えた候補を入れて、点数を付け直す（ジャンル・営業時間・覚えた直しも当て直す）
    private func remerge(_ ranked: [PlaceCandidate], fresh: [PlaceCandidate], lines: [String], label: String, genre: String?,
                         date: Date, indoor: Bool, spot: (latitude: Double, longitude: Double)) -> [PlaceCandidate] {
        var merged = Matcher.rank(PlaceFinder.merge([ranked, fresh]), lines: lines, dishLabel: label)
        merged = Matcher.applyHours(Matcher.applyGenre(merged, photoGenre: genre), at: date)
        // 点数を付け直すと消えるので、写真が似ている・向いていた先 の上乗せをもう一度
        merged = Matcher.applyDirection(Matcher.applyAlike(merged), shots: [])
        merged = Array(merged.prefix(indoor ? 20 : 12))
        let learned = Corrections.lookup(latitude: spot.latitude, longitude: spot.longitude)
        return Matcher.applyCorrections(merged, right: learned.right, wrong: learned.wrong)
    }

    /// 案3: 文字のある所を、元の写真の細かさから大きく切り出す。切り出した絵（送れる形）と、そこから読めた文字
    private func zoom(asset: PHAsset, boxes: [CGRect], size: CGSize) async -> (data: Data, lines: [String])? {
        guard let unit = TextZoom.region(boxes, imageSize: size), let big = await PhotoLoader.image(asset, side: 2600),
              let cut = TextZoom.crop(big, unit: unit, maxSide: TextZoom.isWide(unit) ? 1568 : 1280),
              TextZoom.isBigger(cut.size, unit: unit) else { return nil }
        let text = await Task.detached(priority: .utility) { PhotoVision.text(cut) }.value
        guard let data = await sendable(cut) else { return nil }
        Metrics.count("textZooms")
        return (data, text)
    }

    /// 案1: 前に行った候補のお店で、この人が前に撮った写真（見比べ用。4 軒まで・1 軒 2 枚まで・顔は隠す）
    private func ownShopPhotos(_ shops: [PlaceCandidate], except meal: Meal, context: ModelContext) async -> [String: [Data]] {
        guard AISettings.ownPhotos else { return [:] }
        var out: [String: [Data]] = [:]
        let skip = Set(meal.photoIDs)
        for shop in shops where (shop.visited || shop.alike) && !shop.closedThen {
            if out.count >= 4 { break }
            guard let place = PlaceBook.existing(for: shop, context: context) else { continue }
            var photos: [Data] = []
            for id in OwnPhotos.photoIDs(of: place, except: skip) {
                guard let image = await ThumbCache.shared.image(id, side: 512), let data = await sendable(image) else { continue }
                photos.append(data)
            }
            if !photos.isEmpty { out[shop.key] = photos }
        }
        return out
    }

    /// 案10: はじめてのお店は、名物をネットで調べて、料理名をお店での呼び名に合わせる（新しい写真だけ・月の上限つき）。
    /// 調べた料理名はお店に覚えておき、2 回目からは AI に渡すだけにする
    private func nameDishes(_ meal: Meal, photo: Data?, old: Bool) async {
        guard !old, let place = meal.place, meal.eatenOut, !meal.aiPending, meal.confidence >= Matcher.sureLine,
              !meal.dishes.isEmpty, place.menuNames.isEmpty, ShopMenu.due(place.menuCheckedAt), ShopMenu.canUse else { return }
        status = "お店の料理名を調べています"
        let area = [meal.region, meal.area].filter { !$0.isEmpty }.joined(separator: " ")
        let found: ShopMenu.Answer?
        do {
            found = try await ShopMenu.lookup(shop: place.name, address: place.address, area: area, genre: meal.genre,
                                              dishes: meal.dishes, photo: photo)
        } catch {
            // 通信の失敗などは、次にこのお店に来たときにもう一度
            return
        }
        // 調べ終わった印（見つからなくても、しばらくは調べ直さない）
        place.menuCheckedAt = Date()
        guard let answer = found else { return }
        place.menuNames = answer.menu
        if !answer.menu.isEmpty, let renamed = ShopMenu.renamed(old: meal.dishes, new: answer.dishes) {
            meal.dishes = Matcher.canonicalDishes(renamed, book: dishBook)
            Metrics.count("dishRenames")
        }
    }

    /// 名前で探し直す。いまのお店と名前がもう合っていれば nil
    private func research(name: String, current: Place?, latitude: Double, longitude: Double, radius: Double = 1000,
                          google: Bool = false) async -> PlaceCandidate? {
        let core = Matcher.coreName(name)
        if let current, Matcher.similarity(Matcher.coreName(current.name), core) >= 0.6 { return nil }
        let results: [PlaceCandidate]
        if google {
            results = await PlaceFinder.searchWithFallback(name, latitude: latitude, longitude: longitude, radius: radius)
        } else {
            results = await PlaceFinder.searchAll(name, latitude: latitude, longitude: longitude, radius: radius)
        }
        guard let best = results.max(by: { Matcher.similarity(Matcher.coreName($0.name), core) < Matcher.similarity(Matcher.coreName($1.name), core) }) else {
            return nil
        }
        let score = Matcher.similarity(Matcher.coreName(best.name), core)
        // いまお店が決まっているなら、よりはっきり合うときだけ置きかえる
        return score >= (current == nil ? 0.6 : 0.8) ? best : nil
    }

    private func setPlace(_ candidate: PlaceCandidate, on meal: Meal, confidence: Double, reason: String, context: ModelContext) {
        let place = PlaceBook.place(for: candidate, date: meal.date, context: context)
        meal.place = place
        meal.eatenOut = true
        meal.confidence = confidence
        meal.reason = reason
        meal.needsCheck = confidence < Matcher.sureLine
        if meal.genre == "その他", let g = Matcher.candidateGenre(candidate) { meal.genre = g }
        var list = meal.candidates
        if !list.contains(where: { $0.key == candidate.key }) {
            list.insert(candidate, at: 0)
            meal.candidates = list
        }
    }

    /// 答え（無ければ端末の判断）を食事に書く
    func apply(_ verdict: MealVerdict?, to meal: Meal, ranked: [PlaceCandidate], forcedPick: PlaceCandidate?, context: ModelContext,
               labels: [String: Double] = [:], lines: [String] = []) {
        var pick: PlaceCandidate?
        var confidence = 0.0
        let receipt = meal.reason.contains("レシート")
        if let verdict {
            meal.eatenOut = verdict.eaten_out && meal.spot.isEmpty
            meal.genre = verdict.genre
            meal.dishes = Matcher.canonicalDishes(verdict.dishes.filter { !$0.isEmpty }, book: dishBook)
            meal.summary = verdict.summary
            meal.kind = verdict.kind
            if !verdict.is_meal { meal.hidden = true }
            if let forcedPick {
                pick = forcedPick
                confidence = max(0.85, verdict.place_confidence)
            } else if meal.eatenOut {
                (pick, confidence) = Matcher.decide(ranked: ranked, aiIndex: verdict.place_index, aiConfidence: verdict.place_confidence)
            } else {
                confidence = verdict.place_confidence
            }
            meal.reason = pick == nil ? "" : (verdict.reason.isEmpty ? Matcher.reason(for: pick, source: meal.source, receipt: receipt) : verdict.reason)
            // AI が「その他」にしたら、お店の名前から分かるジャンルを使う
            if meal.genre == "その他", let pick, let g = Matcher.candidateGenre(pick) { meal.genre = g }
        } else {
            if let forcedPick {
                pick = forcedPick
                confidence = 0.85
            } else if meal.spot.isEmpty {
                (pick, confidence) = Matcher.decideOnDevice(ranked)
            } else {
                meal.eatenOut = false
                confidence = 1
            }
            if pick != nil, pick!.score < 0.25, forcedPick == nil { pick = nil }
            // ジャンルと料理: お店の名前 → 写真の文字 → 本人が直したジャンル → 写真の判定 の順に見る（2026-11-24）
            let seen = labels.isEmpty && !meal.visionLabel.isEmpty ? [meal.visionLabel: 0.5] : labels
            if let guess = Matcher.guessGenre(labels: seen, lines: lines, shopName: pick?.name, learned: GenreLearn.lookup(meal.visionLabel)) {
                meal.genre = guess.genre
                if let dish = guess.dish { meal.dishes = Matcher.canonicalDishes([dish], book: dishBook) }
            }
            if Matcher.isLight(meal.visionLabel), meal.genre == "カフェ" || meal.genre == "スイーツ" || meal.genre == "その他" {
                meal.kind = ["coffee", "tea", "juice", "smoothie", "drink", "beverage"].contains(meal.visionLabel) ? "drink" : "snack"
            }
            if meal.genre == "その他", let pick, let g = Matcher.candidateGenre(pick) { meal.genre = g }
            meal.reason = Matcher.reason(for: pick, source: forcedPick != nil ? "known" : "device", receipt: false)
        }
        // ジャンルを料理の名前・お店とそろえる（本人が直したものは触らない）
        if !meal.genreByHand {
            meal.genre = Matcher.consistentGenre(meal.genre, dishes: meal.dishes, shop: meal.eatenOut ? pick : nil, shopConfidence: confidence)
        }
        if let pick, meal.eatenOut {
            let place = PlaceBook.place(for: pick, date: meal.date, context: context)
            meal.place = place
            if place.phone.isEmpty, !pick.phone.isEmpty { place.phone = pick.phone }
        } else if verdict != nil {
            meal.place = nil
        }
        meal.confidence = confidence
        meal.needsCheck = !meal.hidden && meal.spot.isEmpty && meal.eatenOut && confidence < Matcher.sureLine
    }

    /// 送ってよい形の JPEG（人の顔を隠す。便72）
    private func sendable(_ image: UIImage) async -> Data? {
        let hide = AISettings.hideFaces
        return await Task.detached(priority: .utility) {
            let shown = hide ? PhotoVision.hidingFaces(image) : image
            return shown.jpegData(compressionQuality: 0.7)
        }.value
    }

    private func loadImage(_ photo: SeenPhoto, side: CGFloat) async -> UIImage? {
        if ImportedPhotos.isFile(photo.id) { return await ImportedPhotos.image(photo.id, side: side) }
        guard let asset = PhotoLoader.asset(photo.id) else { return nil }
        if photo.isVideo { return await PhotoLoader.videoFrame(asset, side: side) }
        return await PhotoLoader.image(asset, side: side)
    }

    // MARK: - あとで AI に見てもらう（便70・便13）

    /// 圏外で聞けなかった食事を、つながったときに聞き直す（1回に 10 件まで）
    private func retryPending(context: ModelContext) async {
        guard ClaudeLink.isReady, Net.shared.online else { return }
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.aiPending && !$0.hidden })
        let meals = ((try? context.fetch(descriptor)) ?? []).filter { $0.source != "batch" }
        for meal in meals.prefix(10) {
            if Task.isCancelled || !Spend.canSpend { break }
            status = "AI に聞き直しています"
            var food: [Data] = []
            for id in Self.spread(meal.photoIDs, count: 3) {
                guard let asset = PhotoLoader.asset(id), let image = await PhotoLoader.image(asset, side: 1024) else { continue }
                if let data = await sendable(image) { food.append(data) }
            }
            guard !food.isEmpty else { meal.aiPending = false; continue }
            let ranked = meal.candidates
            let prompt = ClaudeVision.prompt(date: meal.date, area: meal.area, candidates: ranked, lines: [], foodCount: food.count, clueCount: 0)
            do {
                let verdict = try await ClaudeVision.judge(food: food, clues: [], prompt: prompt)
                let wasChecked = !meal.needsCheck && meal.confidence >= 1
                meal.aiPending = false
                meal.source = "claude"
                // 本人がもう選び直した食事は、お店はそのままにする
                if wasChecked {
                    meal.dishes = Matcher.canonicalDishes(verdict.dishes, book: dishBook)
                    meal.genre = verdict.genre
                    meal.summary = verdict.summary
                } else {
                    apply(verdict, to: meal, ranked: ranked, forcedPick: nil, context: context)
                }
            } catch ClaudeError.offline {
                break
            } catch {
                meal.aiPending = false
            }
        }
        try? context.save()
    }

    /// まとめ処理を送る・答えを受け取る
    private func runBatches(context: ModelContext) async {
        guard ClaudeLink.isReady, Net.shared.online else { return }
        let results = await BatchQueue.collect()
        for (id, result) in results {
            let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == id })
            guard let meal = try? context.fetch(descriptor).first else { continue }
            meal.aiPending = false
            if case .success(let verdict) = result, meal.needsCheck || meal.confidence < 1 {
                apply(verdict, to: meal, ranked: meal.candidates, forcedPick: nil, context: context)
                meal.source = "batch"
            }
        }
        if !results.isEmpty { try? context.save() }
        if !BatchQueue.queued.isEmpty {
            do {
                let sent = try await BatchQueue.submit()
                if sent > 0 { status = "古い写真を \(sent) 件まとめて AI に送りました" }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - 後片づけ

    /// また行きたいお店が、まだマップにあるか（30 日に1回・1回に 5 軒まで。便47）
    private func checkClosed(context: ModelContext) async {
        guard Net.shared.online else { return }
        let places = ((try? context.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.wantAgain }))) ?? [])
            .filter { ($0.closedCheckedAt ?? .distantPast).timeIntervalSinceNow < -30 * 86_400 }
        for place in places.prefix(5) {
            if let there = await PlaceFinder.stillThere(name: place.name, latitude: place.latitude, longitude: place.longitude) {
                place.maybeClosed = !there
            }
            place.closedCheckedAt = Date()
        }
        try? context.save()
    }

    /// 近くに来たら教えるお店を、最新にする（便41）
    func refreshFences(context: ModelContext) async {
        guard LocationWatch.nearAlerts else {
            LocationWatch.shared.updateFences([], near: nil)
            return
        }
        let places = (try? context.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.wantAgain }))) ?? []
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日"
        let list = places.map { p -> (key: String, name: String, latitude: Double, longitude: Double, detail: String) in
            let detail: String
            if let last = p.lastVisit {
                detail = "最後は \(f.string(from: last))・\(p.visibleMeals.first?.dishText ?? "")"
            } else {
                detail = "行ってみたいお店です" + (p.nextWish.isEmpty ? "" : "（\(p.nextWish)）")
            }
            return (p.key, p.name, p.latitude, p.longitude, detail)
        }
        let here = await LocationWatch.shared.current()
        LocationWatch.shared.updateFences(list, near: here)
    }

    /// 似た写真ばかりにならないよう、並びから等間隔に選ぶ
    nonisolated static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        return (0..<count).map { items[$0 * items.count / count] }
    }

    // MARK: - アプリを開いていないときに読む

    /// iOS が別の糸から呼ぶので、画面の糸に縛らない
    nonisolated static func registerBackground() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Scanner.run(task, mode: .normal)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            Scanner.run(task, mode: .quick)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backfillID, using: nil) { task in
            Scanner.run(task, mode: .backfill)
        }
    }

    nonisolated private static func run(_ task: BGTask, mode: Mode) {
        let work = Task { @MainActor in
            let added = await Scanner.shared.scan(mode: mode, notify: true)
            if added > 1 { Notifier.tellAdded(added) }
            task.setTaskCompleted(success: true)
            Scanner.scheduleBackground()
        }
        task.expirationHandler = { work.cancel() }
    }

    nonisolated static func scheduleBackground() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(2 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        // 食べ終わったころに知らせるため、短い読み込みも頼んでおく（いつ動くかは iOS が決める。便24）
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date().addingTimeInterval(75 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    /// 古い写真は、充電中に読む（便6）
    nonisolated static func scheduleBackfill() {
        let request = BGProcessingTaskRequest(identifier: backfillID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// お店の記録を探す・作る
enum PlaceBook {
    @MainActor
    static func place(for candidate: PlaceCandidate, date: Date, context: ModelContext) -> Place {
        if let found = existing(for: candidate, context: context) { return found }
        let place = Place(candidate: candidate, date: date)
        context.insert(place)
        return place
    }

    /// もう記録にあるお店（無ければ nil。作らない）
    @MainActor
    static func existing(for candidate: PlaceCandidate, context: ModelContext) -> Place? {
        if let found = find(key: candidate.key, context: context) { return found }
        // 名前が同じで 150m 以内のお店（行ってみたいで保存したお店など）は、同じお店とみなす
        let name = Matcher.normalize(candidate.name)
        return ((try? context.fetch(FetchDescriptor<Place>())) ?? []).first { p in
            Matcher.normalize(p.name) == name
                && Matcher.distance(p.latitude, p.longitude, candidate.latitude, candidate.longitude) <= 150
        }
    }

    @MainActor
    static func find(key: String, context: ModelContext) -> Place? {
        let descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.key == key })
        return try? context.fetch(descriptor).first
    }

    /// 前に行ったお店（と、行ってみたいお店）のうち、近いもの（地図の検索に出てこなくても候補に入れる）
    @MainActor
    static func visited(near latitude: Double, _ longitude: Double, context: ModelContext) -> [PlaceCandidate] {
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        return places.compactMap { p in
            let d = Matcher.distance(latitude, longitude, p.latitude, p.longitude)
            guard d <= 300 else { return nil }
            var c = PlaceCandidate(name: p.name, address: p.address, category: p.category,
                                   latitude: p.latitude, longitude: p.longitude, distance: d, visited: true, phone: p.phone)
            // 前に調べた料理名があれば、AI への一言にする（案10）
            c.note = ShopMenu.note(p.menuNames)
            return c
        }
    }
}
