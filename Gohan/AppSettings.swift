import CoreLocation
import Foundation
import Network
import UIKit

/// 読む設定
/// 写真の出し方（作る人のメニュー。2026-11-27）
enum PhotoSettings {
    private static let d = UserDefaults.standard
    /// 選べる、表示用に覚えておく絵の上限（MB）
    static let memoryChoices = [60, 120, 200, 300]
    static let defaultMemoryMB = 120

    /// 表示用に覚えておく絵の上限（MB）。選べる値でなければ初めの値
    static var memoryMB: Int {
        get {
            let v = d.integer(forKey: "photo.memoryMB")
            return memoryChoices.contains(v) ? v : defaultMemoryMB
        }
        set { d.set(newValue, forKey: "photo.memoryMB") }
    }
}

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

    /// 食事のあいだに同じ場所で撮った、料理ではない写真（人・お店の中）も食事に入れる（2026-11-25）
    static var companions: Bool {
        get { d.object(forKey: "scan.companions") as? Bool ?? true }
        set { d.set(newValue, forKey: "scan.companions") }
    }

    /// iPhone の訪問の記録（どこに何分いたか）で、食事を区切る（2026-11-26 案4）
    static var visitGroups: Bool {
        get { d.object(forKey: "scan.visitGroups") as? Bool ?? true }
        set { d.set(newValue, forKey: "scan.visitGroups") }
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

    /// 迷ったときだけ、AI にネットで確かめてもらう（3。1 回 数円）
    static var webCheck: Bool {
        get { d.object(forKey: "ai.webCheck") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.webCheck") }
    }

    /// 迷ったときだけ、いちばん強いモデル（Opus）に聞き直す（2026-11-26）
    static var escalate: Bool {
        get { d.object(forKey: "ai.escalate") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.escalate") }
    }

    /// 迷ったとき、料理の写真で画像検索する（Google Cloud Vision。月の上限つき。2026-11-25 実験）
    static var imageSearch: Bool {
        get { d.object(forKey: "ai.imageSearch") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.imageSearch") }
    }

    // 2026-11-26 に足した精度の施策（本人「1・2・3・4・5・6・9・10」）。どれも初めはオン。作る人のメニューで切れる

    /// 前に行ったお店で撮った写真と、見た目を比べる（端末の中で。迷ったときは AI にも見比べてもらう。案1）
    static var ownPhotos: Bool {
        get { d.object(forKey: "ai.ownPhotos") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.ownPhotos") }
    }

    /// お店がはっきりしたら、同じ場所の昔の「迷い」も埋める（案2）
    static var retroFix: Bool {
        get { d.object(forKey: "ai.retroFix") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.retroFix") }
    }

    /// 小さな字のある所を、大きく切り出して AI に見せる（案3。1 枚 1 円くらい＝仮）
    static var zoomText: Bool {
        get { d.object(forKey: "ai.zoomText") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.zoomText") }
    }

    /// 料理の種類が分かったのに、その種類のお店が候補に無いとき、種類の名前で近くを探し直す（案5）
    static var genreSearch: Bool {
        get { d.object(forKey: "ai.genreSearch") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.genreSearch") }
    }

    /// 看板などの写真の向きと、写真の高さを手がかりにする（案9）
    static var direction: Bool {
        get { d.object(forKey: "ai.direction") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.direction") }
    }

    /// はじめてのお店は、名物をネットで調べて料理名を合わせる（案10。1 軒 数円＝仮・月の上限つき）
    static var shopMenu: Bool {
        get { d.object(forKey: "ai.shopMenu") as? Bool ?? true }
        set { d.set(newValue, forKey: "ai.shopMenu") }
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

/// 作る人のメニュー（設定の「版」を 5 回たたくと出る）。ふだんは、費用・AI の状態・エラー・決め方・くわしい設定を隠す
/// （本人「アプリ内で彼女に見えなくて良いものは非表示で」2026-11-24）
enum MakerMode {
    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: "maker.mode") }
        set { UserDefaults.standard.set(newValue, forKey: "maker.mode") }
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
