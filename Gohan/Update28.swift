import Foundation
import QuartzCore
import SwiftData
import SwiftUI
import UIKit

// 2026-11-28 大型アップデートの第 1 弾（案の文書: docs/big-update-2026-11-28.md。公開リポジトリには入れていない）

// MARK: - 大6 場所はあるのにお店が空の食事を、料理の種類の名前で探し直す

enum RetroSearch {
    /// 1 軒に決めてよい近さ（m）
    static let pickReach = 80.0
    /// この中に同じ種類のお店が 2 軒以上あれば、決めない（m）
    static let crowdReach = 150.0
    /// 1 回の読み取りで探す食事の数
    static let perRun = 20
    static let filledConfidence = 0.45
    private static let triedKey = "retroSearch.tried"

    /// 探して見つかったお店から、1 軒に決めてよいか。近くに同じ種類のお店が 1 軒だけで、十分近いときだけ
    static func pick(_ found: [PlaceCandidate], genre: String) -> PlaceCandidate? {
        let same = found.filter { $0.distance <= crowdReach && Matcher.genreFit(photo: genre, candidate: $0) > 0 }
        guard same.count == 1, let only = same.first, only.distance <= pickReach else { return nil }
        return only
    }

    /// 探す相手か（外食・場所あり・お店なし・おうちや職場ではない・まだ探していない）
    static func wanted(hasPlace: Bool, hasLocation: Bool, eatenOut: Bool, spot: String, tried: Bool) -> Bool {
        !hasPlace && hasLocation && eatenOut && spot.isEmpty && !tried
    }

    private static var tried: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: triedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: triedKey) }
    }

    @MainActor
    static func run(context: ModelContext) async {
        guard AISettings.genreSearch, AISettings.retroSearch, Net.shared.online, !EvalMode.on else { return }
        var done = tried
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden && $0.eatenOut })
        let meals = ((try? context.fetch(descriptor)) ?? []).filter {
            wanted(hasPlace: $0.place != nil, hasLocation: $0.latitude != nil, eatenOut: $0.eatenOut, spot: $0.spot,
                   tried: done.contains($0.id.uuidString))
        }
        var changed = false
        for meal in meals.prefix(perRun) {
            if Task.isCancelled { break }
            done.insert(meal.id.uuidString)
            guard let lat = meal.latitude, let lon = meal.longitude,
                  let word = Matcher.genreSearchWord(meal.genre, dishes: meal.dishes) else { continue }
            Metrics.count("retroSearches")
            let found = await PlaceFinder.searchAll(word, latitude: lat, longitude: lon, radius: 200)
                .filter { !Matcher.isConvenienceStore($0.name) }
            guard !found.isEmpty else { continue }
            // 選び直す画面に出るように、見つかったお店を候補に足しておく
            meal.candidates = PlaceFinder.merge([meal.candidates, found])
            changed = true
            guard let shop = pick(found, genre: meal.genre),
                  !Corrections.lookup(latitude: lat, longitude: lon).wrong.contains(Matcher.normalize(shop.name)) else { continue }
            meal.place = PlaceBook.place(for: shop, date: meal.date, context: context)
            meal.confidence = filledConfidence
            meal.needsCheck = true
            meal.reason = "「\(word)」で近くを探して、1 軒だけ見つかりました"
            if !meal.source.contains("+genre") { meal.source += "+genre" }
            Metrics.count("retroSearchFills")
        }
        tried = done
        if changed { try? context.save() }
    }
}

// MARK: - 大11 人ごとのくせ（よく食べる種類）を、写真で種類が分からないときの点に少し足す

enum Habits {
    static let minMeals = 30
    static let minShare = 0.4
    static let bump = 0.06
    private static let key = "habit.topGenre"

    /// いちばん多い種類（数が少ない・割合が低いときは nil）
    static func top(_ genres: [String]) -> (genre: String, share: Double)? {
        let known = genres.filter { !$0.isEmpty && $0 != "その他" }
        guard known.count >= minMeals else { return nil }
        var count: [String: Int] = [:]
        for g in known { count[g, default: 0] += 1 }
        guard let best = count.max(by: { $0.value < $1.value }) else { return nil }
        let share = Double(best.value) / Double(known.count)
        return share >= minShare ? (best.key, share) : nil
    }

    static var topGenre: String? { AISettings.habits ? UserDefaults.standard.string(forKey: key) : nil }

    @MainActor
    static func refresh(context: ModelContext) {
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden && $0.eatenOut })
        let genres = ((try? context.fetch(descriptor)) ?? []).map(\.genre)
        UserDefaults.standard.set(top(genres)?.genre, forKey: key)
    }

    /// 写真から種類が分からなかったときだけ、くせの種類のお店を少し上げる
    static func apply(_ ranked: [PlaceCandidate], photoGenre: String?, habit: String?) -> [PlaceCandidate] {
        guard photoGenre == nil || photoGenre == "その他", let habit else { return ranked }
        return ranked.map { c in
            var c = c
            let fit = Matcher.genreFit(photo: habit, candidate: c)
            if fit > 0 { c.score = min(1, c.score + bump * fit) }
            return c
        }
        .sorted { $0.score > $1.score }
    }
}

// MARK: - 大9 直したときに、候補ごとの点の内訳も残す（あとで重みを決め直すため）

struct CandidateFeature: Codable, Equatable {
    var name: String
    var distance: Double
    var textHit: Double
    var visited: Bool
    var genre: String?
    var score: Double
    var closedThen: Bool

    init(_ c: PlaceCandidate) {
        name = c.name
        distance = (c.distance * 10).rounded() / 10
        textHit = (c.textHit * 100).rounded() / 100
        visited = c.visited
        genre = Matcher.candidateGenre(c)
        score = (c.score * 1000).rounded() / 1000
        closedThen = c.closedThen
    }

    static func list(_ candidates: [PlaceCandidate], limit: Int = 8) -> [CandidateFeature] {
        candidates.prefix(limit).map(CandidateFeature.init)
    }
}

// MARK: - 大12 当たり具合の記録を、選んだファイル（ドライブなど）へ自動で上書きする（作る人のメニュー）

enum AccuracySync {
    private static let key = "accuracy.syncBookmark"
    private static let lastKey = "accuracy.syncLast"

    static var isSet: Bool { UserDefaults.standard.data(forKey: key) != nil }
    static var last: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }

    static func choose(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let mark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(mark, forKey: key)
        }
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: key) }

    /// 記録をそのファイルに書く（失敗しても何もしない）
    static func push() async {
        guard let mark = UserDefaults.standard.data(forKey: key), let data = AccuracyLog.exportData() else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: mark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        let wrote = await Task.detached(priority: .utility) { () -> Bool in
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            var done = false
            var err: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
                done = (try? data.write(to: u)) != nil
            }
            return done && err == nil
        }.value
        if wrote {
            UserDefaults.standard.set(Date(), forKey: lastKey)
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: key)
            }
        }
    }
}

// MARK: - 大22 遅さを測る（固まった回数と、画面が出るまでの時間。作る人のメニューで見る）

@MainActor
final class Slowness {
    static let shared = Slowness()
    nonisolated static let tick = 0.25
    /// これより長く止まったら「固まった」と数える（秒）
    nonisolated static let hangLine = 0.5
    /// 画面が出るまでがこれより長ければ数える（秒）
    nonisolated static let slowLine = 0.3
    private var watching = false

    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var markedAt: CFTimeInterval?

    func start() {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: Self.tick, repeats: true) { _ in
            MainActor.assumeIsolated { Slowness.shared.beat() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        guard !watching else { return }
        watching = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Slowness.shared.pause() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Slowness.shared.start() }
        }
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
    }

    private func beat() {
        let now = CACurrentMediaTime()
        let lag = now - last - Self.tick
        last = now
        if let lagged = Self.hang(lag) { Self.note("hang", seconds: lagged) }
    }

    /// 止まっていた長さ（数えるほどでなければ nil）
    nonisolated static func hang(_ lag: Double) -> Double? { lag > hangLine ? lag : nil }

    /// 画面を切り替え始めた（タブを押した など）
    func mark() { markedAt = CACurrentMediaTime() }

    /// 画面が出た
    func appeared(_ screen: String) {
        guard let start = markedAt else { return }
        markedAt = nil
        let took = CACurrentMediaTime() - start
        if took > Self.slowLine { Self.note("slow.\(screen)", seconds: took) }
    }

    private static func note(_ name: String, seconds: Double) {
        Metrics.count(name)
        let key = "slowest.\(Metrics.thisMonth).\(name)"
        if seconds > UserDefaults.standard.double(forKey: key) { UserDefaults.standard.set(seconds, forKey: key) }
    }

    static func worst(_ name: String) -> Double { UserDefaults.standard.double(forKey: "slowest.\(Metrics.thisMonth).\(name)") }

    nonisolated static let screens = ["きろく", "また行きたい", "地図"]
}

// MARK: - 大20 月の終わりに「今月のごはん」を 1 通

enum MonthlyNote {
    private static let key = "monthly.sent"

    /// 知らせる月（"yyyy-MM"）。月の 1〜7 日に、先月の分をまだ知らせていなければ
    static func due(now: Date, lastSent: String?, calendar: Calendar = .current) -> String? {
        guard calendar.component(.day, from: now) <= 7,
              let prev = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: prev)
        let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return month == lastSent ? nil : month
    }

    static func text(month: Int, meals: Int, shops: Int, first: Int) -> String {
        var s = "\(month)月は \(meals) 食・\(shops) 軒"
        if first > 0 { s += "（はじめて \(first) 軒）" }
        return s + "。まとめを見てみませんか。"
    }

    @MainActor
    static func sendIfDue(context: ModelContext, now: Date = Date()) {
        guard AISettings.monthlyNote, let month = due(now: now, lastSent: UserDefaults.standard.string(forKey: key)) else { return }
        UserDefaults.standard.set(month, forKey: key)
        let calendar = Calendar.current
        guard let prev = calendar.date(byAdding: .month, value: -1, to: now),
              let range = calendar.dateInterval(of: .month, for: prev) else { return }
        let start = range.start, end = range.end
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden && $0.date >= start && $0.date < end })
        let meals = (try? context.fetch(descriptor)) ?? []
        guard !meals.isEmpty else { return }
        let shops = Set(meals.compactMap { $0.place?.key }).count
        let first = meals.filter { $0.place != nil && $0.visitNumber == 1 }.count
        Notifier.tellMonth(title: "\(calendar.component(.month, from: prev))月のごはん",
                           body: text(month: calendar.component(.month, from: prev), meals: meals.count, shops: shops, first: first))
    }
}

// MARK: - 大21 種類ごとの帖（年ごとの数・お店の順位・行った都道府県）

struct GenreBook {
    struct Row: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let count: Int
    }

    let total: Int
    let years: [Row]
    let shops: [Row]
    let regions: [Row]

    static func make(dates: [Date], shops: [String?], regions: [String], calendar: Calendar = .current) -> GenreBook {
        func rows(_ items: [String], limit: Int) -> [Row] {
            var count: [String: Int] = [:]
            for i in items where !i.isEmpty { count[i, default: 0] += 1 }
            return count.map { Row(name: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
                .prefix(limit).map { $0 }
        }
        let years = rows(dates.map { String(calendar.component(.year, from: $0)) }, limit: 100).sorted { $0.name > $1.name }
        return GenreBook(total: dates.count, years: years, shops: rows(shops.compactMap { $0 }, limit: 20),
                         regions: rows(regions, limit: 47))
    }
}

struct GenreBookView: View {
    let genre: String
    let meals: [Meal]

    var body: some View {
        let book = GenreBook.make(dates: meals.map(\.date), shops: meals.map { $0.place?.name }, regions: meals.map(\.region))
        List {
            Section {
                LabeledContent("ぜんぶで", value: "\(book.total)食")
                LabeledContent("お店", value: "\(Set(meals.compactMap { $0.place?.key }).count)軒")
            }
            Section("年ごと") {
                ForEach(book.years) { LabeledContent($0.name + "年", value: "\($0.count)食") }
            }
            if !book.shops.isEmpty {
                Section("よく行ったお店") {
                    ForEach(Array(book.shops.enumerated()), id: \.element.id) { i, row in
                        LabeledContent("\(i + 1). \(row.name)", value: "\(row.count)回")
                    }
                }
            }
            if !book.regions.isEmpty {
                Section("食べた都道府県（\(book.regions.count)）") {
                    ForEach(book.regions) { LabeledContent($0.name, value: "\($0.count)食") }
                }
            }
        }
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 作る人のメニューの 1 区切り

struct BigUpdateSection: View {
    @State private var retroSearch = AISettings.retroSearch
    @State private var habits = AISettings.habits
    @State private var monthly = AISettings.monthlyNote
    @State private var picking = false
    @State private var synced = AccuracySync.isSet

    var body: some View {
        Section {
            Toggle("お店が空の食事を、料理の種類で探し直す", isOn: $retroSearch).onChange(of: retroSearch) { _, new in AISettings.retroSearch = new }
            Toggle("よく食べる種類（\(Habits.topGenre ?? "まだ分からない")）を少し優先", isOn: $habits)
                .onChange(of: habits) { _, new in AISettings.habits = new }
            Toggle("月のはじめに「先月のごはん」を知らせる", isOn: $monthly).onChange(of: monthly) { _, new in AISettings.monthlyNote = new }
            if synced {
                LabeledContent("当たり具合の自動の書き出し", value: AccuracySync.last.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "まだ")
                Button("書き出し先を外す", role: .destructive) { AccuracySync.forget(); synced = false }
            } else {
                Button("当たり具合を自動で書き出すファイルを選ぶ") { picking = true }
            }
            LabeledContent("今月 固まった", value: "\(Metrics.value("hang")) 回（最長 \(String(format: "%.1f", Slowness.worst("hang"))) 秒）")
            ForEach(Slowness.screens, id: \.self) { s in
                LabeledContent("今月 \(s) が遅かった", value: "\(Metrics.value("slow.\(s)")) 回（最長 \(String(format: "%.1f", Slowness.worst("slow.\(s)"))) 秒）")
            }
            LabeledContent("今月 種類で探し直した", value: "\(Metrics.value("retroSearches")) 食（埋めた \(Metrics.value("retroSearchFills"))）")
        } header: {
            Text("大型アップデート（2026-11-28）")
        } footer: {
            Text("書き出し先は、ドライブなどに置いた「ごはん帖の当たり具合.json」を選びます。直したり「合ってる」を押したりするたびに上書きします。固まった回数は、画面が 0.5 秒より長く止まった回数です。線はどれも仮の値です。")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            AccuracySync.choose(url)
            synced = AccuracySync.isSet
            Task { await AccuracySync.push() }
        }
    }
}
