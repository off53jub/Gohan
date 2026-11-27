import CoreLocation
import CoreSpotlight
import EventKit
import Foundation
import LocalAuthentication
import Observation
import Photos
import SwiftData
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// 画面の行き先（通知・Spotlight・ショートカットから開くとき）
@MainActor
@Observable
final class Router {
    static let shared = Router()

    enum Tab: Hashable { case log, want, map }

    var tab: Tab = .log
    /// 開きたい食事
    var openMeal: UUID?
    /// 開きたいお店（キー）
    var openPlace: String?
    /// 探したいことば
    var searchQuery: String?
    var showOneYear = false
}

/// 「元に戻す」（便56）。消す・分ける・くっつける・お店を変える のあとに、下に少し出す
@MainActor
@Observable
final class UndoCenter {
    static let shared = UndoCenter()
    private(set) var message: String?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func offer(_ message: String, undo: @escaping () -> Void) {
        self.message = message
        action = undo
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled { self.dismiss() }
        }
    }

    func undo() {
        action?()
        Metrics.count("undo")
        dismiss()
    }

    func dismiss() {
        message = nil
        action = nil
    }
}

/// 直したら覚える（便51）。場所ごとに「このお店が正しい」「このお店は違う」を覚える
enum Corrections {
    private struct Entry: Codable {
        var right: [String] = []
        var wrong: [String] = []
    }

    private static var all: [String: Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "corrections") else { return [:] }
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "corrections") }
    }

    static func learn(latitude: Double?, longitude: Double?, wrong: String?, right: String?) {
        guard let latitude, let longitude else { return }
        let key = Matcher.spotKey(latitude: latitude, longitude: longitude)
        var entry = all[key] ?? Entry()
        if let wrong {
            let n = Matcher.normalize(wrong)
            if !entry.wrong.contains(n) { entry.wrong.append(n) }
            entry.right.removeAll { $0 == n }
        }
        if let right {
            let n = Matcher.normalize(right)
            if !entry.right.contains(n) { entry.right.append(n) }
            entry.wrong.removeAll { $0 == n }
        }
        var copy = all
        copy[key] = entry
        all = copy
        Metrics.count("corrections")
    }

    static func lookup(latitude: Double, longitude: Double) -> (right: Set<String>, wrong: Set<String>) {
        // 試験のあいだは、本人が直した覚えを使わない（答えを見ながら解かないように）
        guard !EvalMode.on, let entry = all[Matcher.spotKey(latitude: latitude, longitude: longitude)] else { return ([], []) }
        return (Set(entry.right), Set(entry.wrong))
    }
}

/// 知らせ
enum Notifier {
    static func ask() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func tellAdded(_ count: Int) {
        post(title: "ごはん帖", body: "新しい食事を \(count) 件記録しました", id: "added-\(Date().timeIntervalSince1970)")
    }

    /// 食べ終わったころに「今日のごはん、入りました」（写真つき。便24）
    static func tellMeal(title: String, dishes: String, mealID: UUID, thumbnail: Data?) {
        let content = UNMutableNotificationContent()
        content.title = "今日のごはん、入りました"
        content.body = dishes.isEmpty ? title : "\(title)・\(dishes)"
        content.userInfo = ["meal": mealID.uuidString]
        if let thumbnail {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(mealID.uuidString).jpg")
            if (try? thumbnail.write(to: url)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "photo", url: url, options: nil) {
                content.attachments = [attachment]
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "meal-\(mealID.uuidString)", content: content, trigger: nil))
    }

    static func tellInitialDone(_ meals: Int) {
        post(title: "ごはん帖", body: "これまでの写真から \(meals) 食みつけました", id: "initial-done")
    }

    /// 月のはじめに「先月のごはん」（大20）
    static func tellMonth(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["stats": "1"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "month-\(title)", content: content, trigger: nil))
    }

    static func tellNear(name: String, detail: String, key: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(name) の近くです"
        content.body = detail
        content.userInfo = ["place": key]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "near-\(key)", content: content, trigger: nil))
    }

    private static func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// 通知を押したときに、その食事・お店を開く
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func start() { UNUserNotificationCenter.current().delegate = self }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let meal = (info["meal"] as? String).flatMap(UUID.init(uuidString:))
        let place = info["place"] as? String
        await MainActor.run {
            if let meal { Router.shared.tab = .log; Router.shared.openMeal = meal }
            if let place { Router.shared.tab = .want; Router.shared.openPlace = place }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// 位置（いまいる所・近くに来たら教える。便41・便42）
@MainActor
final class LocationWatch: NSObject, CLLocationManagerDelegate {
    static let shared = LocationWatch()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    private var authWaiting: [CheckedContinuation<Void, Never>] = []

    /// 近くに来たら教える（初めはオフ。「常に」の許可が要る）
    static var nearAlerts: Bool {
        get { UserDefaults.standard.bool(forKey: "near.alerts") }
        set { UserDefaults.standard.set(newValue, forKey: "near.alerts") }
    }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        startVisits()
    }

    /// iPhone の「訪問」の記録を受け取り始める（「常に」の許可があるときだけ。電池はほとんど使わない。精度1）
    func startVisits() {
        guard status == .authorizedAlways else { return }
        manager.startMonitoringVisits()
    }

    /// 1回だけ、「常に」の許可を聞く（訪問の記録に要る。断られたら二度と聞かない）
    func askAlwaysOnce() {
        guard !UserDefaults.standard.bool(forKey: "visits.asked"),
              status == .authorizedWhenInUse || status == .notDetermined else { return }
        UserDefaults.standard.set(true, forKey: "visits.asked")
        manager.requestAlwaysAuthorization()
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// いまいる所（許可が無ければ聞く。10 秒で諦める）
    func current() async -> CLLocation? {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            await withCheckedContinuation { authWaiting.append($0) }
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -120 { return recent }
        manager.requestLocation()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            self.finish(nil)
        }
        let location = await withCheckedContinuation { waiting.append($0) }
        timeout.cancel()
        return location
    }

    func askAlways() { manager.requestAlwaysAuthorization() }

    /// また行きたいお店のうち、近い 20 軒を見張る（iOS の上限が 20）
    func updateFences(_ places: [(key: String, name: String, latitude: Double, longitude: Double, detail: String)], near: CLLocation?) {
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
        guard Self.nearAlerts, status == .authorizedAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let sorted = places.sorted { a, b in
            guard let near else { return a.name < b.name }
            return near.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                < near.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        var details: [String: String] = [:]
        for p in sorted.prefix(20) {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude), radius: 150, identifier: p.key)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
            details[p.key] = "\(p.name)\n\(p.detail)"
        }
        UserDefaults.standard.set(details, forKey: "near.details")
    }

    private func finish(_ location: CLLocation?) {
        let list = waiting
        waiting = []
        for c in list { c.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let item = Visit(arrival: visit.arrivalDate == Date.distantPast ? nil : visit.arrivalDate,
                         departure: visit.departureDate == Date.distantFuture ? nil : visit.departureDate,
                         latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
                         accuracy: visit.horizontalAccuracy)
        Task { @MainActor in VisitLog.save(VisitLog.add(item, to: VisitLog.load())) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.startVisits()
            let list = self.authWaiting
            self.authWaiting = []
            for c in list { c.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let key = region.identifier
        let details = UserDefaults.standard.dictionary(forKey: "near.details") as? [String: String] ?? [:]
        guard let text = details[key] else { return }
        // 同じお店は 1 日に 1 回まで
        let sentKey = "near.sent.\(key)"
        if let last = UserDefaults.standard.object(forKey: sentKey) as? Date, last.timeIntervalSinceNow > -86_400 { return }
        UserDefaults.standard.set(Date(), forKey: sentKey)
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        Notifier.tellNear(name: parts.first ?? "", detail: parts.count > 1 ? parts[1] : "また行きたいお店です", key: key)
    }
}

/// アプリを開いている間に写真が増えたら、読めるころに読む（便23）
@MainActor
final class PhotoWatch: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoWatch()
    private var pending: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return }
        started = true
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.schedule() }
    }

    /// 撮ってから 1 時間待つ決まりなので、そのころに読む（アプリを開いているときだけ）
    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(Matcher.holdBack + 60))
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active, ScanSettings.auto else { return }
            await Scanner.shared.scan()
        }
    }
}

/// 予定表の手がかり（便17。初めはオフ）
enum CalendarClue {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "calendar.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "calendar.enabled") }
    }

    static func request() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// その時刻の前後 1 時間の予定（「名前（場所）」）
    static func event(around date: Date) -> String? {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-3600), end: date.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }
        guard let e = events.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }) else { return nil }
        let title = e.title ?? ""
        let place = e.location ?? ""
        return place.isEmpty ? title : "\(title)（\(place)）"
    }
}

/// iPhone の検索に出す（便38）
enum Spotlight {
    static func index(_ meals: [Meal]) {
        let items = meals.map { meal -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = meal.title
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "yyyy年M月d日"
            attributes.contentDescription = "\(meal.dishText)・\(f.string(from: meal.date))"
            attributes.keywords = meal.dishes + [meal.genre, meal.area, "ごはん"]
            return CSSearchableItem(uniqueIdentifier: meal.id.uuidString, domainIdentifier: "meal", attributeSet: attributes)
        }
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items, completionHandler: nil)
    }

    static func remove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids.map(\.uuidString), completionHandler: nil)
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteAllSearchableItems(completionHandler: nil)
    }
}

/// Face ID で開く（便74。初めはオフ）
enum FaceLock {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lock.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "lock.enabled") }
    }

    static func unlock() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "ごはん帖をひらきます")) ?? false
    }
}

/// 写真に場所が入っているか（便3）
enum LocationCheck {
    /// 最近のカメラの写真のうち、場所が入っている割合（写真が少なければ nil）
    static func ratio() -> Double? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 60
        let result = PHAsset.fetchAssets(with: options)
        var total = 0, located = 0
        result.enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            total += 1
            if asset.location != nil { located += 1 }
        }
        guard total >= 10 else { return nil }
        return Double(located) / Double(total)
    }
}
