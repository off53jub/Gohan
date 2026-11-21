import BackgroundTasks
import Foundation
import Observation
import Photos
import SwiftData
import UIKit
import UserNotifications

/// 見た写真の覚え（写真アプリの ID → 端末で見た結果）。食べ物でない写真も覚えておく（看板・メニューの手がかりに使う）
enum SeenStore {
    private static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("seen-photos.json")
    }

    static func load() -> [String: SeenPhoto] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SeenPhoto].self, from: data)) ?? [:]
    }

    static func save(_ seen: [String: SeenPhoto]) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(seen) { try? data.write(to: url, options: .atomic) }
    }

    static func reset() { try? FileManager.default.removeItem(at: url) }
}

/// 読む設定
enum ScanSettings {
    /// この日より後に撮った写真を読む
    static var since: Date {
        get { UserDefaults.standard.object(forKey: "scan.since") as? Date ?? Date().addingTimeInterval(-30 * 86_400) }
        set { UserDefaults.standard.set(newValue, forKey: "scan.since") }
    }

    /// アプリを開いたら読む（初めはオン）
    static var auto: Bool {
        get { UserDefaults.standard.object(forKey: "scan.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "scan.auto") }
    }

    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }
}

/// 写真を読んで、食事の記録を作る
@MainActor
@Observable
final class Scanner {
    static let shared = Scanner()
    nonisolated static let taskID = "com.off53jub.gohan.scan"

    var isRunning = false
    var status = ""
    var lastError: String?
    var lastRun: Date?
    @ObservationIgnored var container: ModelContainer?

    /// 新しい写真を読む。作った食事の数を返す
    @discardableResult
    func scan() async -> Int {
        guard let container, !isRunning else { return 0 }
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            lastError = "写真を見る許可がありません（設定アプリ → ごはん帖 → 写真）"
            return 0
        }
        isRunning = true
        lastError = nil
        defer {
            isRunning = false
            status = ""
            lastRun = Date()
        }

        var seen = SeenStore.load()
        let cutoff = Date().addingTimeInterval(-Matcher.holdBack)
        let fresh = newAssets(since: ScanSettings.since, before: cutoff, seen: seen)

        // 1. どの写真が食べ物か（端末の中だけで見る）
        for (i, asset) in fresh.enumerated() {
            if Task.isCancelled { break }
            status = "写真を見ています \(i + 1)/\(fresh.count)"
            var look = PhotoVision.Look(food: 0, label: "")
            if let image = await PhotoLoader.image(asset, side: 360) {
                look = await Task.detached(priority: .utility) { PhotoVision.look(image) }.value
            }
            let location = asset.location
            seen[asset.localIdentifier] = SeenPhoto(
                id: asset.localIdentifier,
                date: asset.creationDate ?? Date(),
                latitude: location?.coordinate.latitude,
                longitude: location?.coordinate.longitude,
                accuracy: location?.horizontalAccuracy,
                food: look.food,
                label: look.label
            )
            if i % 40 == 39 { SeenStore.save(seen) }
        }
        SeenStore.save(seen)

        // 2. 食べ物の写真を食事にまとめ、お店と料理を決める
        let all = Array(seen.values)
        let pending = all.filter { $0.food >= Matcher.foodThreshold && !$0.used && $0.date < cutoff }
        let groups = Matcher.groupMeals(pending)
        let context = container.mainContext
        var added = 0
        for (i, group) in groups.enumerated() {
            if Task.isCancelled { break }
            status = "お店を調べています \(i + 1)/\(groups.count)"
            if appendToRecentMeal(group, context: context) == false {
                if await buildMeal(group, all: all, context: context) { added += 1 }
            }
            for photo in group { seen[photo.id]?.used = true }
            SeenStore.save(seen)
            try? context.save()
        }
        return added
    }

    private func newAssets(since: Date, before: Date, seen: [String: SeenPhoto]) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate > %@ AND creationDate < %@",
                                        PHAssetMediaType.image.rawValue, since as NSDate, before as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if seen[asset.localIdentifier] == nil, !asset.mediaSubtypes.contains(.photoScreenshot) { out.append(asset) }
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

    /// 1回の食事を作る。作ったら true（食事でないと分かったときは、消した扱いで残して false）
    private func buildMeal(_ group: [SeenPhoto], all: [SeenPhoto], context: ModelContext) async -> Bool {
        guard let first = group.first, let last = group.last else { return false }
        let spot = Matcher.center(of: group)
        let meal = Meal(date: first.date, endDate: last.date, photoIDs: group.map(\.id),
                        latitude: spot?.latitude, longitude: spot?.longitude)

        // 料理の写真（多ければ散らして3枚）と、前後の手がかりの写真
        var lines: [String] = []
        var foodJPEGs: [Data] = []
        for photo in Self.spread(group.sorted { $0.food > $1.food }, count: 3) {
            guard let asset = PhotoLoader.asset(photo.id), let image = await PhotoLoader.image(asset, side: 1024) else { continue }
            lines += await Task.detached(priority: .utility) { PhotoVision.text(image) }.value
            if let data = image.jpegData(compressionQuality: 0.7) { foodJPEGs.append(data) }
        }
        var clueShots: [(data: Data, count: Int)] = []
        for photo in Matcher.cluePhotos(for: group, among: all) {
            guard let asset = PhotoLoader.asset(photo.id), let image = await PhotoLoader.image(asset, side: 1024) else { continue }
            let text = await Task.detached(priority: .utility) { PhotoVision.text(image) }.value
            guard !text.isEmpty else { continue }
            lines += text
            if let data = image.jpegData(compressionQuality: 0.7) { clueShots.append((data, text.count)) }
        }
        let clueJPEGs = clueShots.sorted { $0.count > $1.count }.prefix(2).map(\.data)

        // お店の候補（近くの飲食店・写真の文字で探したお店・前に行ったお店）
        var candidates: [PlaceCandidate] = []
        if let spot {
            let accuracy = group.compactMap(\.accuracy).filter { $0 > 0 }.min() ?? 50
            let radius = min(300, max(80, accuracy * 2))
            var lists = [await PlaceFinder.nearby(latitude: spot.latitude, longitude: spot.longitude, radius: radius)]
            for query in Matcher.searchableLines(lines) {
                lists.append(await PlaceFinder.search(query, latitude: spot.latitude, longitude: spot.longitude, radius: 700))
            }
            lists.append(PlaceBook.visited(near: spot.latitude, spot.longitude, context: context))
            candidates = PlaceFinder.merge(lists)
            meal.area = await PlaceFinder.area(latitude: spot.latitude, longitude: spot.longitude)
        }
        let label = group.max { $0.food < $1.food }?.label ?? ""
        let ranked = Array(Matcher.rank(candidates, lines: lines, dishLabel: label).prefix(12))
        meal.candidates = ranked

        // Claude に見てもらう（鍵があって、今月の上限の内なら）
        var verdict: MealVerdict?
        if ClaudeVision.isReady, Spend.canSpend, !foodJPEGs.isEmpty {
            let prompt = ClaudeVision.prompt(date: first.date, area: meal.area, candidates: ranked, lines: lines,
                                             foodCount: foodJPEGs.count, clueCount: clueJPEGs.count)
            do {
                verdict = try await ClaudeVision.judge(food: foodJPEGs, clues: Array(clueJPEGs), prompt: prompt)
                meal.source = "claude"
            } catch {
                lastError = error.localizedDescription
            }
        }

        var pick: PlaceCandidate?
        var confidence = 0.0
        if let verdict {
            meal.eatenOut = verdict.eaten_out
            meal.genre = verdict.genre
            meal.dishes = verdict.dishes.filter { !$0.isEmpty }
            meal.summary = verdict.summary
            if !verdict.is_meal { meal.hidden = true }
            if verdict.eaten_out {
                (pick, confidence) = Matcher.decide(ranked: ranked, aiIndex: verdict.place_index, aiConfidence: verdict.place_confidence)
            } else {
                confidence = verdict.place_confidence
            }
        } else {
            (pick, confidence) = Matcher.decideOnDevice(ranked)
            if let dish = Matcher.dishNames[label] {
                meal.dishes = [dish.dish]
                meal.genre = dish.genre
            }
            if meal.genre == "その他", let pick, let g = Genre.from(category: pick.category) { meal.genre = g }
        }
        if let pick, meal.eatenOut, verdict != nil || pick.score >= 0.25 {
            meal.place = PlaceBook.place(for: pick, date: first.date, context: context)
        }
        meal.confidence = confidence
        meal.needsCheck = !meal.hidden && confidence < Matcher.sureLine
        context.insert(meal)
        return !meal.hidden
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
            let work = Task { @MainActor in
                let added = await Scanner.shared.scan()
                if added > 0 { Notifier.tellAdded(added) }
                task.setTaskCompleted(success: true)
                Scanner.scheduleBackground()
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    nonisolated static func scheduleBackground() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(2 * 3600)
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
        let place = Place(candidate: candidate, date: date)
        context.insert(place)
        return place
    }

    /// 前に行ったお店のうち、近いもの（地図の検索に出てこなくても候補に入れる）
    @MainActor
    static func visited(near latitude: Double, _ longitude: Double, context: ModelContext) -> [PlaceCandidate] {
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        return places.compactMap { p in
            let d = Matcher.distance(latitude, longitude, p.latitude, p.longitude)
            guard d <= 300 else { return nil }
            return PlaceCandidate(name: p.name, address: p.address, category: p.category,
                                  latitude: p.latitude, longitude: p.longitude, distance: d, visited: true)
        }
    }
}

/// 知らせ
enum Notifier {
    static func ask() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func tellAdded(_ count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "ごはん帖"
        content.body = "新しい食事を \(count) 件記録しました"
        let request = UNNotificationRequest(identifier: "added-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
