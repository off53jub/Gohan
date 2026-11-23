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
    @ObservationIgnored private var dishBook: [String: String] = [:]

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
        let groups = Matcher.groupMeals(Matcher.fillLocations(pending, among: all))
        var added: [Meal] = []
        for (i, group) in groups.enumerated() {
            if Task.isCancelled { break }
            status = "お店を調べています \(i + 1)/\(groups.count)"
            if appendToRecentMeal(group, context: context) == false {
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

        // 4. 後片づけ（検索・バックアップ・閉店チェック・近くに来たら）
        Spotlight.index(added)
        for meal in added { Backup.fillCloudIDs(meal) }
        try? context.save()
        Backup.autoWrite(context: context)
        await checkClosed(context: context)
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
        return SeenPhoto(
            id: asset.localIdentifier,
            date: asset.creationDate ?? Date(),
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            accuracy: location?.horizontalAccuracy,
            food: result.food,
            label: result.label,
            isVideo: isVideo,
            noCamera: noCamera
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
    private func appendToRecentMeal(_ group: [SeenPhoto], context: ModelContext) -> Bool {
        guard let first = group.first, let last = group.last else { return true }
        let from = first.date.addingTimeInterval(-Matcher.mealGap)
        let to = first.date
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.endDate >= from && $0.endDate <= to })
        guard let meals = try? context.fetch(descriptor) else { return false }
        let spot = Matcher.center(of: group)
        for meal in meals where !meal.hidden {
            if let spot, let lat = meal.latitude, let lon = meal.longitude,
               Matcher.distance(lat, lon, spot.latitude, spot.longitude) > Matcher.mealDistance { continue }
            meal.photoIDs.append(contentsOf: group.map(\.id).filter { !meal.photoIDs.contains($0) })
            meal.endDate = max(meal.endDate, last.date)
            return true
        }
        return false
    }

    /// 1回の食事を作る。作ったら返す（食事でないと分かったときは、消した扱いで残して nil）
    private func buildMeal(_ group: [SeenPhoto], all: [SeenPhoto], context: ModelContext, old: Bool) async -> Meal? {
        guard let first = group.first, let last = group.last else { return nil }
        let spot = Matcher.center(of: group)
        let meal = Meal(date: first.date, endDate: last.date, photoIDs: group.map(\.id),
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
        var lines: [String] = []
        var foodJPEGs: [Data] = []
        for photo in Self.spread(group.sorted { $0.food > $1.food }, count: 3) {
            guard let image = await loadImage(photo, side: 1024) else { continue }
            lines += await Task.detached(priority: .utility) { PhotoVision.text(image) }.value
            if let data = await sendable(image) { foodJPEGs.append(data) }
        }
        var clueShots: [(id: String, data: Data, count: Int)] = []
        for photo in Matcher.cluePhotos(for: group, among: all) {
            guard let asset = PhotoLoader.asset(photo.id), let image = await PhotoLoader.image(asset, side: 1024) else { continue }
            let text = await Task.detached(priority: .utility) { PhotoVision.text(image) }.value
            guard !text.isEmpty else { continue }
            lines += text
            if let data = await sendable(image) { clueShots.append((photo.id, data, text.count)) }
        }
        let topClues = clueShots.sorted { $0.count > $1.count }.prefix(2)
        meal.cluePhotoIDs = topClues.map(\.id)
        let clueJPEGs = topClues.map(\.data)
        let receipt = Matcher.receiptNames(lines)
        let event = CalendarClue.event(around: first.date)

        // お店の候補（近くの飲食店・写真の文字で探したお店・予定の場所・前に行ったお店）
        var candidates: [PlaceCandidate] = []
        if let spot, meal.spot.isEmpty {
            let accuracy = group.compactMap(\.accuracy).filter { $0 > 0 }.min() ?? 50
            let radius = min(300, max(80, accuracy * 2))
            var lists = [await PlaceFinder.nearby(latitude: spot.latitude, longitude: spot.longitude, radius: radius)]
            var queries = receipt + Matcher.searchableLines(lines)
            if let event { queries.append(event) }
            for query in queries.prefix(5) {
                lists.append(await PlaceFinder.search(query, latitude: spot.latitude, longitude: spot.longitude, radius: 700))
            }
            lists.append(PlaceBook.visited(near: spot.latitude, spot.longitude, context: context))
            candidates = PlaceFinder.merge(lists)
        }
        var ranked = Array(Matcher.rank(candidates, lines: lines + receipt, dishLabel: label).prefix(12))
        if let spot {
            let learned = Corrections.lookup(latitude: spot.latitude, longitude: spot.longitude)
            ranked = Matcher.applyCorrections(ranked, right: learned.right, wrong: learned.wrong)
        }
        meal.candidates = ranked

        // 決め方を選ぶ
        let ready = ClaudeLink.isReady && Spend.canSpend && !foodJPEGs.isEmpty
        let known = meal.spot.isEmpty ? Matcher.knownPlace(ranked) : nil
        var verdict: MealVerdict?
        if ready {
            let light = AISettings.lightForEasy && (known != nil || !meal.spot.isEmpty || Matcher.isEasy(ranked))
            let prompt = ClaudeVision.prompt(date: first.date, area: meal.area, candidates: known.map { [$0] } ?? ranked, lines: lines,
                                             foodCount: foodJPEGs.count, clueCount: clueJPEGs.count, event: event, receipt: receipt,
                                             knownPlace: known.map { "\($0.name)（\($0.address)）" })
            if old, AISettings.batchOld, known == nil, meal.spot.isEmpty {
                // 古い写真は急がないので、まとめ処理で半額に（便13）。答えが来るまでは端末で決めておく
                BatchQueue.enqueue(mealID: meal.id, body: ClaudeVision.body(food: foodJPEGs, clues: Array(clueJPEGs), prompt: prompt, light: false))
                meal.aiPending = true
                meal.source = "batch"
            } else {
                do {
                    verdict = try await ClaudeVision.judge(food: foodJPEGs, clues: Array(clueJPEGs), prompt: prompt, light: light)
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
            apply(verdict, to: meal, ranked: [known], forcedPick: known, context: context)
            if verdict == nil { meal.source = "known" }
        } else {
            apply(verdict, to: meal, ranked: ranked, forcedPick: nil, context: context)
        }
        context.insert(meal)
        return meal.hidden ? nil : meal
    }

    /// 答え（無ければ端末の判断）を食事に書く
    func apply(_ verdict: MealVerdict?, to meal: Meal, ranked: [PlaceCandidate], forcedPick: PlaceCandidate?, context: ModelContext) {
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
            if let dish = Matcher.dishNames[meal.visionLabel] {
                meal.dishes = Matcher.canonicalDishes([dish.dish], book: dishBook)
                meal.genre = dish.genre
                if Matcher.isLight(meal.visionLabel) { meal.kind = ["coffee", "tea", "juice", "smoothie", "drink", "beverage"].contains(meal.visionLabel) ? "drink" : "snack" }
            }
            if meal.genre == "その他", let pick, let g = Genre.from(category: pick.category) { meal.genre = g }
            if pick != nil, pick!.score < 0.25, forcedPick == nil { pick = nil }
            meal.reason = Matcher.reason(for: pick, source: forcedPick != nil ? "known" : "device", receipt: false)
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
        let key = candidate.key
        let descriptor = FetchDescriptor<Place>(predicate: #Predicate { $0.key == key })
        if let found = try? context.fetch(descriptor).first { return found }
        // 名前が同じで 150m 以内のお店（行ってみたいで保存したお店など）は、同じお店とみなす
        let name = Matcher.normalize(candidate.name)
        let near = ((try? context.fetch(FetchDescriptor<Place>())) ?? []).first { p in
            Matcher.normalize(p.name) == name
                && Matcher.distance(p.latitude, p.longitude, candidate.latitude, candidate.longitude) <= 150
        }
        if let near { return near }
        let place = Place(candidate: candidate, date: date)
        context.insert(place)
        return place
    }

    /// 前に行ったお店（と、行ってみたいお店）のうち、近いもの（地図の検索に出てこなくても候補に入れる）
    @MainActor
    static func visited(near latitude: Double, _ longitude: Double, context: ModelContext) -> [PlaceCandidate] {
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        return places.compactMap { p in
            let d = Matcher.distance(latitude, longitude, p.latitude, p.longitude)
            guard d <= 300 else { return nil }
            return PlaceCandidate(name: p.name, address: p.address, category: p.category,
                                  latitude: p.latitude, longitude: p.longitude, distance: d, visited: true, phone: p.phone)
        }
    }
}
