import CoreLocation
import Foundation
import Network
import UIKit

/// 読む設定
enum ScanSettings {
    private static let d = UserDefaults.standard

    /// この日より後に撮った写真を読む
    static var since: Date {
        get { d.object(forKey: "scan.since") as? Date ?? Date().addingTimeInterval(-30 * 86_400) }
        set { d.set(newValue, forKey: "scan.since") }
    }

    /// アプリを開いたら読む（初めはオン）
    static var auto: Bool {
        get { d.object(forKey: "scan.auto") as? Bool ?? true }
        set { d.set(newValue, forKey: "scan.auto") }
    }

    static var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    /// 初めの読み込みが終わったか（終わったら一度だけ知らせる）
    static var initialDone: Bool {
        get { d.bool(forKey: "scan.initialDone") }
        set { d.set(newValue, forKey: "scan.initialDone") }
    }

    /// 古い写真は、充電中で Wi-Fi のときにまとめて読む（便6）
    static var backfillOnlyCharging: Bool {
        get { d.object(forKey: "scan.backfillCharging") as? Bool ?? true }
        set { d.set(newValue, forKey: "scan.backfillCharging") }
    }

    /// 動画からも1コマ拾う（便21）
    static var videos: Bool {
        get { d.object(forKey: "scan.videos") as? Bool ?? true }
        set { d.set(newValue, forKey: "scan.videos") }
    }

    /// 飲み物だけ・おやつの記録も一覧に並べる（便26）
    static var showSmall: Bool {
        get { d.object(forKey: "show.small") as? Bool ?? true }
        set { d.set(newValue, forKey: "show.small") }
    }
}

/// AI の使い方
enum AISettings {
    private static let d = UserDefaults.standard

    /// 端末だけで決める（写真を送らない。便75）
    static var deviceOnly: Bool {
        get { d.bool(forKey: "ai.deviceOnly") }
        set { d.set(newValue, forKey: "ai.deviceOnly") }
    }

    /// 人の顔を隠してから送る（便72）
    static var hideFaces: Bool {
        get { d.object(forKey: "ai.hideFaces") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.hideFaces") }
    }

    /// 古い写真はまとめ処理で安く（便13）
    static var batchOld: Bool {
        get { d.object(forKey: "ai.batchOld") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.batchOld") }
    }

    /// かんたんな写真は軽いモデルで（便12）
    static var lightForEasy: Bool {
        get { d.object(forKey: "ai.light") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.light") }
    }

    /// 費用をこの端末で見せる（便76。鍵を QR で受け取った端末では初めは見せない）
    static var showCost: Bool {
        get { d.object(forKey: "ai.showCost") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.showCost") }
    }

    /// 中継サーバー（便2）。空なら直接 Anthropic に送る
    static var relayURL: String {
        get { d.string(forKey: "ai.relayURL") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.relayURL") }
    }
}

/// おうち・職場の場所（便14・便15）
enum Spots {
    private static let d = UserDefaults.standard
    static let radius = 150.0

    static func get(_ name: String) -> CLLocationCoordinate2D? {
        guard d.object(forKey: "spot.\(name).lat") != nil else { return nil }
        return CLLocationCoordinate2D(latitude: d.double(forKey: "spot.\(name).lat"), longitude: d.double(forKey: "spot.\(name).lon"))
    }

    static func set(_ name: String, _ c: CLLocationCoordinate2D?) {
        if let c {
            d.set(c.latitude, forKey: "spot.\(name).lat")
            d.set(c.longitude, forKey: "spot.\(name).lon")
        } else {
            d.removeObject(forKey: "spot.\(name).lat")
            d.removeObject(forKey: "spot.\(name).lon")
        }
    }

    /// その位置が おうち・職場 なら "home"・"work"
    static func which(latitude: Double, longitude: Double) -> String {
        for name in ["home", "work"] {
            if let c = get(name), Matcher.distance(latitude, longitude, c.latitude, c.longitude) <= radius { return name }
        }
        return ""
    }
}

/// 記念日（便65）
struct Anniversary: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var month: Int
    var day: Int

    static var all: [Anniversary] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "anniversaries") else { return [] }
            return (try? JSONDecoder().decode([Anniversary].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "anniversaries") }
    }

    static func on(_ date: Date) -> Anniversary? {
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        return all.first { $0.month == parts.month && $0.day == parts.day }
    }
}

/// 通信の具合（Wi-Fi か・つながっているか）
final class Net: @unchecked Sendable {
    static let shared = Net()
    private let monitor = NWPathMonitor()
    private(set) var online = true
    private(set) var onWiFi = false

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.online = path.status == .satisfied
            self?.onWiFi = path.usesInterfaceType(.wifi)
        }
        monitor.start(queue: DispatchQueue(label: "gohan.net"))
    }
}

/// 古い写真をまとめて読んでよいか（充電中で Wi-Fi のとき）
enum Backfill {
    @MainActor static var allowed: Bool {
        if !ScanSettings.backfillOnlyCharging { return true }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        return charging && Net.shared.onWiFi
    }
}

/// 作る側の物差し（直された回数など。便58）
enum Metrics {
    private static let d = UserDefaults.standard

    private static var month: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func count(_ name: String) {
        let key = "metric.\(month).\(name)"
        d.set(d.integer(forKey: key) + 1, forKey: key)
    }

    static func value(_ name: String, month m: String? = nil) -> Int {
        d.integer(forKey: "metric.\(m ?? month).\(name)")
    }

    static var thisMonth: String { month }
}
