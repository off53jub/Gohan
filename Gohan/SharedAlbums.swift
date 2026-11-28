import Photos
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// 2026-11-28 「ういきょ」で始まる共有アルバムの、ごはんの写真を数える（取り込む前の試し）。
// 数えるだけで、食事も写真も何も書き換えない。作る人のメニューにだけ出す。

enum SharedAlbums {
    static let prefix = "ういきょ"

    /// アルバムの名前が「ういきょ」で始まるか（カタカナの「ウイキョ」・前の空白も同じに見る）
    static func matches(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hira = t.applyingTransform(.hiraganaToKatakana, reverse: true) ?? t
        return hira.hasPrefix(prefix)
    }

    static func albums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        var out: [PHAssetCollection] = []
        result.enumerateObjects { c, _, _ in
            if matches(c.localizedTitle ?? "") { out.append(c) }
        }
        return out
    }

    /// 1 つのアルバムの数
    struct Tally: Identifiable, Equatable {
        var name: String
        var id: String { name }
        var photos = 0
        var food = 0
        /// ごはんの写真のうち、位置が残っているもの
        var located = 0
        /// ごはんの写真のうち、本人の食事の時間（前後 30 分）に入るもの
        var duringMyMeal = 0
        /// ごはんの写真のうち、本人の写真ライブラリに同じ時刻（2 秒以内）の写真があるもの（自分で載せた写真らしい）
        var sameAsMine = 0
        var first: Date?
        var last: Date?

        mutating func add(date: Date?, isFood: Bool, hasLocation: Bool, inMyMeal: Bool, mine: Bool) {
            photos += 1
            if let date {
                first = min(first ?? date, date)
                last = max(last ?? date, date)
            }
            guard isFood else { return }
            food += 1
            if hasLocation { located += 1 }
            if inMyMeal { duringMyMeal += 1 }
            if mine { sameAsMine += 1 }
        }
    }

    /// 本人の食事の時間に入るか（spans は開始で並べたもの）
    static func inMeal(_ date: Date, spans: [(Date, Date)], margin: TimeInterval = 30 * 60) -> Bool {
        spans.contains { date >= $0.0.addingTimeInterval(-margin) && date <= $0.1.addingTimeInterval(margin) }
    }

    /// 本人のライブラリに、同じ時刻の写真があるか
    static func hasOwnPhoto(at date: Date) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        date.addingTimeInterval(-2) as NSDate, date.addingTimeInterval(2) as NSDate)
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).count > 0
    }
}

/// 作る人のメニューの「ういきょのアルバムを数える」
struct SharedAlbumSection: View {
    @Environment(\.modelContext) private var context
    @State private var tallies: [SharedAlbums.Tally] = []
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var note: String?
    @State private var job: Task<Void, Never>?
    @State private var pickingTimeline = false
    @State private var timelineCount = 0

    var body: some View {
        Section {
            if running {
                HStack {
                    ProgressView()
                    Text("数えています \(done) / \(total)")
                }
                Button("やめる", role: .cancel) { job?.cancel() }
            } else {
                Button("ういきょのアルバムを数える") { job = Task { await count() } }
                Button("ういきょのごはんを取り込む") { job = Task { await importNow() } }
                NavigationLink("取り込みの結果を見直す") { UikyoReviewView() }
                Button("Google のタイムラインを読む（今 \(timelineCount) 点）") { pickingTimeline = true }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            ForEach(tallies) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.subheadline.bold())
                    Text("写真 \(t.photos) 枚・ごはんらしい \(t.food) 枚")
                    Text("ごはんのうち 位置あり \(t.located)・自分の食事の時間 \(t.duringMyMeal)・自分の写真と同じ時刻 \(t.sameAsMine)")
                    if let f = t.first, let l = t.last {
                        Text("\(f.formatted(.dateTime.year().month().day()))〜\(l.formatted(.dateTime.year().month().day()))")
                    }
                }
                .font(.caption)
            }
        } header: {
            Text("共有アルバム（試し・2026-11-28）")
        } footer: {
            Text("数えるほうは、食事も写真も変えません。取り込むほうは、自分の食事の時間に重なる写真をその食事に足し、重ならない写真は新しい食事にします（ういきょの写真は自分もいた食事として扱う）。場所の無い写真は、Google のタイムラインのその時刻の滞在先を使います。写真が多いと数分〜数十分かかります。")
        }
        .task { timelineCount = await Task.detached { GoogleTimeline.load().count }.value }
        .onDisappear { job?.cancel() }
        .fileImporter(isPresented: $pickingTimeline, allowedContentTypes: [.json]) { picked in
            guard case .success(let url) = picked else { return }
            job = Task { await readTimeline(url) }
        }
    }

    private func readTimeline(_ url: URL) async {
        running = true
        defer { running = false }
        let scoped = url.startAccessingSecurityScopedResource()
        let read = await Task.detached { () -> (spots: [GoogleTimeline.Spot], why: String) in
            guard let data = GoogleTimeline.read(url) else { return ([], "ファイルが開けませんでした") }
            let spots = GoogleTimeline.parse(data)
            if spots.isEmpty { return ([], GoogleTimeline.describe(data)) }
            GoogleTimeline.save(spots)
            return (spots, "")
        }.value
        if scoped { url.stopAccessingSecurityScopedResource() }
        let spots = read.spots
        guard !spots.isEmpty else { note = "タイムラインとして読めませんでした（\(read.why)）。"; return }
        timelineCount = spots.count
        note = "タイムラインを \(spots.count) 点読みました。場所の無い食事に位置を入れています…"
        let filled = await GoogleTimeline.fillMealLocations(spots, context: context)
        note = "タイムラインを \(spots.count) 点読み、場所の無い食事 \(filled) 食に位置を入れました。ういきょの取り込みでも使います。"
    }

    private func importNow() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            note = "写真へのアクセスが「すべての写真」になっていないので、共有アルバムが読めません。"
            return
        }
        running = true
        defer { running = false }
        note = nil
        let r = await SharedAlbums.importFood(context: context) { d, t in done = d; total = t }
        note = "見た \(r.looked) 枚（前に取り込み済み \(r.already)）・ごはん \(r.food) 枚。"
            + "自分の食事 \(r.mealsTouched) 食に写真を \(r.addedToMeals) 枚足し、うち \(r.locationsAdded) 食に場所を入れました。"
            + "一緒に食べた食事を \(r.newMeals) 食つくりました。"
            + "うち場所の無い写真 \(r.noLocation) 枚は、タイムラインの滞在先で補いました。"
            + (Task.isCancelled ? "（途中でやめました）" : "")
    }

    private func count() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            note = "写真へのアクセスが「すべての写真」になっていないので、共有アルバムが読めません。"
            return
        }
        let albums = SharedAlbums.albums()
        guard !albums.isEmpty else {
            note = "「ういきょ」で始まる共有アルバムが見つかりませんでした（写真の設定で「共有アルバム」がオンか確かめてください）。"
            return
        }
        running = true
        defer { running = false }
        note = nil
        tallies = []
        done = 0
        let meals = (try? context.fetch(FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.date)]))) ?? []
        let spans = meals.filter { !$0.hidden }.map { ($0.date, $0.endDate) }
        var lists: [(String, PHFetchResult<PHAsset>)] = []
        for album in albums {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            lists.append((album.localizedTitle ?? "?", PHAsset.fetchAssets(in: album, options: options)))
        }
        total = lists.reduce(0) { $0 + $1.1.count }
        for (name, assets) in lists {
            var tally = SharedAlbums.Tally(name: name)
            tallies.append(tally)
            for i in 0..<assets.count {
                if Task.isCancelled { note = "途中でやめました。"; return }
                let asset = assets.object(at: i)
                var food = false
                if let image = await PhotoLoader.image(asset, side: 360) {
                    let look = await Task.detached(priority: .utility) { PhotoVision.look(image) }.value
                    food = look.food >= Matcher.foodThreshold
                }
                let date = asset.creationDate
                tally.add(date: date, isFood: food, hasLocation: asset.location != nil,
                          inMyMeal: date.map { SharedAlbums.inMeal($0, spans: spans) } ?? false,
                          mine: food && date.map(SharedAlbums.hasOwnPhoto(at:)) == true)
                done += 1
                if i % 10 == 0 { tallies[tallies.count - 1] = tally }
            }
            tallies[tallies.count - 1] = tally
        }
        note = "数え終わりました。"
    }
}

// MARK: - 取り込み（2026-11-28）
// 1. 本人の食事の時間（前後 30 分）に重なる写真 → その食事に写真を足す（場所が無ければ写真の場所を入れる）
// 2. 重ならないが場所がある写真 → その時刻に本人が同じ所（300m 以内）にいたなら、一緒に食べた食事として作る
//    （本人がいた証拠: iPhone の訪問の記録、または本人のライブラリの前後 60 分の写真の場所）
// 3. それ以外（ういちゃんひとりの食事・場所も無い）→ 載せない
// 作る人のメニューのボタンでだけ動く（ういちゃんの iPhone では押さない）。

extension SharedAlbums {
    static let thereDistance = 300.0
    static let thereWindow: TimeInterval = 60 * 60
    static let doneKey = "sharedAlbum.imported"

    /// 時間と場所が近い写真を 1 回の食事にまとめる
    static func groups(_ photos: [SeenPhoto]) -> [[SeenPhoto]] {
        var out: [[SeenPhoto]] = []
        for p in photos.sorted(by: { $0.date < $1.date }) {
            if let last = out.last?.last, p.date.timeIntervalSince(last.date) <= Matcher.mealGap {
                if let a = last.latitude, let b = last.longitude, let c = p.latitude, let d = p.longitude,
                   Matcher.distance(a, b, c, d) > Matcher.mealDistance {
                    out.append([p])
                } else {
                    out[out.count - 1].append(p)
                }
            } else {
                out.append([p])
            }
        }
        return out
    }

    /// その時刻に本人が同じ所にいたか
    static func wasThere(latitude: Double, longitude: Double, from: Date, to: Date,
                         visits: [Visit], ownSpots: [(date: Date, latitude: Double, longitude: Double)]) -> Bool {
        let slack: TimeInterval = 10 * 60
        for v in visits {
            guard let arrival = v.arrival else { continue }
            let departure = v.departure ?? arrival
            guard arrival.addingTimeInterval(-slack) <= to, departure.addingTimeInterval(slack) >= from else { continue }
            if Matcher.distance(v.latitude, v.longitude, latitude, longitude) <= thereDistance { return true }
        }
        return ownSpots.contains { s in
            s.date >= from.addingTimeInterval(-thereWindow) && s.date <= to.addingTimeInterval(thereWindow)
                && Matcher.distance(s.latitude, s.longitude, latitude, longitude) <= thereDistance
        }
    }

    /// 本人のライブラリの、その時間の前後の写真の場所
    static func ownSpots(from: Date, to: Date) -> [(date: Date, latitude: Double, longitude: Double)] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        from.addingTimeInterval(-thereWindow) as NSDate, to.addingTimeInterval(thereWindow) as NSDate)
        options.includeAssetSourceTypes = [.typeUserLibrary]
        var out: [(date: Date, latitude: Double, longitude: Double)] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { a, _, _ in
            if let l = a.location, let d = a.creationDate { out.append((d, l.coordinate.latitude, l.coordinate.longitude)) }
        }
        return out
    }

    /// 取り込みで、写真のまとまりをどうしたか（作る人のメニューで見直す。2026-11-28）
    struct Logged: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case added, made, notThere, noLocation, byHand }
        var ids: [String]
        var date: Date
        var kind: Kind
        var id: String { ids.first ?? "" }

        var label: String {
            switch kind {
            case .added: return "自分の食事に足した"
            case .made: return "一緒に食べた食事にした"
            case .notThere: return "自分がいなかった"
            case .noLocation: return "場所が無い"
            case .byHand: return "手で入れた"
            }
        }
        var skipped: Bool { kind == .notThere || kind == .noLocation }

        private static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("uikyo-log.json")
        }
        static func load() -> [Logged] {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([Logged].self, from: data)) ?? []
        }
        /// 前の記録に、新しい結果を上書きで足す（同じ写真のまとまりは新しいほう）
        static func merged(_ old: [Logged], _ new: [Logged]) -> [Logged] {
            var byID: [String: Logged] = [:]
            for l in old + new { byID[l.id] = l }
            return byID.values.sorted { $0.date > $1.date }
        }
        static func merge(_ new: [Logged]) {
            let all = merged(load(), new)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// 載せなかったまとまりを、本人が選んで自分の帖に入れる
    @MainActor
    static func addByHand(_ entry: Logged, context: ModelContext) async -> Bool {
        var photos: [SeenPhoto] = []
        for id in entry.ids {
            guard let asset = PhotoLoader.asset(id) else { continue }
            photos.append(await Scanner.shared.look(asset))
        }
        guard !photos.isEmpty else { return false }
        photos = located(photos, timeline: GoogleTimeline.load())
        let meal = await Scanner.shared.buildMeal(photos, all: photos, context: context, old: true)
        if let meal, !meal.source.contains("+uikyo") { meal.source += "+uikyo" }
        try? context.save()
        var done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        done.formUnion(entry.ids)
        UserDefaults.standard.set(Array(done), forKey: doneKey)
        var hand = entry
        hand.kind = .byHand
        Logged.merge([hand])
        return meal != nil
    }

    /// 場所の無い写真に、その時刻の Google のタイムラインの滞在先を入れる
    static func located(_ group: [SeenPhoto], timeline: [GoogleTimeline.Spot]) -> [SeenPhoto] {
        group.map { p in
            guard p.latitude == nil, let s = GoogleTimeline.stay(at: p.date, in: timeline) else { return p }
            var q = p
            q.latitude = s.latitude
            q.longitude = s.longitude
            q.accuracy = 100
            return q
        }
    }

    struct ImportResult {
        var looked = 0
        var food = 0
        var addedToMeals = 0
        var mealsTouched = 0
        var locationsAdded = 0
        var newMeals = 0
        var notThere = 0
        var noLocation = 0
        var already = 0
    }

    @MainActor
    static func importFood(context: ModelContext, progress: @escaping @MainActor (Int, Int) -> Void) async -> ImportResult {
        var result = ImportResult()
        var done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        var assets: [PHAsset] = []
        for album in albums() {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let r = PHAsset.fetchAssets(in: album, options: options)
            r.enumerateObjects { a, _, _ in assets.append(a) }
        }
        // 1 枚ずつ端末の中で見て、ごはんの写真だけ残す
        var food: [SeenPhoto] = []
        for (i, asset) in assets.enumerated() {
            if Task.isCancelled { return result }
            progress(i + 1, assets.count)
            result.looked += 1
            if done.contains(asset.localIdentifier) { result.already += 1; continue }
            let seen = await Scanner.shared.look(asset)
            if seen.food >= Matcher.foodThreshold { food.append(seen) }
        }
        result.food = food.count
        var log: [Logged] = []
        defer { Logged.merge(log) }
        let timeline = GoogleTimeline.load()
        let visits = VisitLog.load() + GoogleTimeline.visits(timeline)
        for group in groups(food) {
            if Task.isCancelled { break }
            guard let first = group.first, let last = group.last else { continue }
            let from = first.date.addingTimeInterval(-30 * 60)
            let to = last.date.addingTimeInterval(30 * 60)
            let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.endDate >= from && $0.date <= to })
            let near = ((try? context.fetch(descriptor)) ?? []).filter { !$0.hidden }
            let ids = group.map(\.id)
            let spot = Matcher.center(of: group)
            if let meal = near.min(by: { abs($0.date.timeIntervalSince(first.date)) < abs($1.date.timeIntervalSince(first.date)) }) {
                // 1. 重なる食事に写真を足す
                let fresh = ids.filter { !meal.photoIDs.contains($0) }
                meal.photoIDs.append(contentsOf: fresh)
                result.addedToMeals += fresh.count
                result.mealsTouched += 1
                log.append(Logged(ids: ids, date: first.date, kind: .added))
                if meal.latitude == nil, meal.place == nil, meal.spot.isEmpty, let spot {
                    meal.latitude = spot.latitude
                    meal.longitude = spot.longitude
                    let p = await PlaceFinder.areaAndRegion(latitude: spot.latitude, longitude: spot.longitude)
                    if meal.area.isEmpty { meal.area = p.area }
                    if meal.region.isEmpty { meal.region = p.region }
                    result.locationsAdded += 1
                }
                if !meal.source.contains("+uikyo") { meal.source += "+uikyo" }
                done.formUnion(ids)
            } else {
                // 2. 重なる食事が無くても、ういきょの写真は本人もいた食事（2026-11-28 本人「全部俺いる」）。
                //    写真に場所が無ければ、Google のタイムラインのその時刻の滞在先を使う
                let photos = located(group, timeline: timeline)
                if let meal = await Scanner.shared.buildMeal(photos, all: photos, context: context, old: true) {
                    if !meal.source.contains("+uikyo") { meal.source += "+uikyo" }
                    result.newMeals += 1
                    if spot == nil { result.noLocation += group.count }
                    log.append(Logged(ids: ids, date: first.date, kind: .made))
                }
                done.formUnion(ids)
            }
            try? context.save()
            UserDefaults.standard.set(Array(done), forKey: doneKey)
        }
        try? context.save()
        UserDefaults.standard.set(Array(done), forKey: doneKey)
        Metrics.count("uikyoImports")
        return result
    }
}

/// ういきょの取り込みの結果を見直す。載せなかったまとまりは「入れる」で自分の帖に入れられる
struct UikyoReviewView: View {
    @Environment(\.modelContext) private var context
    @State private var all: [SharedAlbums.Logged] = []
    @State private var onlySkipped = true
    @State private var onlyAnniversary = false
    @State private var busy: String?
    @State private var days: [Anniversary] = []
    @State private var progress: Int?
    @State private var job: Task<Void, Never>?

    private var shown: [SharedAlbums.Logged] {
        all.filter { (!onlySkipped || $0.skipped) && (!onlyAnniversary || UikyoReviewView.near($0.date, days)) }
    }

    /// 記念日・誕生日の前後 3 日
    static func near(_ date: Date, _ days: [Anniversary]) -> Bool {
        (-3...3).contains { offset in
            let parts = Calendar.current.dateComponents([.month, .day], from: date.addingTimeInterval(Double(offset) * 86_400))
            return days.contains { $0.month == parts.month && $0.day == parts.day }
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("載せなかったものだけ", isOn: $onlySkipped)
                Toggle("記念日の前後 3 日だけ", isOn: $onlyAnniversary)
                Text("\(shown.count) まとまり（全部で \(all.count)）").font(.caption).foregroundStyle(.secondary)
                let rest = shown.filter(\.skipped)
                if !rest.isEmpty {
                    if let progress {
                        Text("入れています \(progress) / \(rest.count)")
                    } else {
                        Button("載せなかった \(rest.count) まとまりを全部入れる") { job = Task { await addAll(rest) } }
                            .disabled(busy != nil)
                    }
                }
            }
            ForEach(shown) { entry in
                HStack(spacing: 10) {
                    PhotoThumb(id: entry.ids.first, side: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date.formatted(.dateTime.year().month().day().hour().minute())).font(.subheadline)
                        Text("\(entry.label)・\(entry.ids.count) 枚" + (UikyoReviewView.near(entry.date, days) ? "・記念日の頃" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.skipped {
                        if busy == entry.id {
                            ProgressView()
                        } else {
                            Button("入れる") { Task { await add(entry) } }.buttonStyle(.bordered).disabled(busy != nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("ういきょの取り込み")
        .onDisappear { job?.cancel() }
        .task {
            days = Anniversary.all
            all = await Task.detached { SharedAlbums.Logged.load() }.value
        }
    }

    private func addAll(_ list: [SharedAlbums.Logged]) async {
        progress = 0
        defer { progress = nil }
        for (i, entry) in list.enumerated() {
            if Task.isCancelled { break }
            progress = i + 1
            _ = await SharedAlbums.addByHand(entry, context: context)
        }
        all = await Task.detached { SharedAlbums.Logged.load() }.value
    }

    private func add(_ entry: SharedAlbums.Logged) async {
        busy = entry.id
        defer { busy = nil }
        _ = await SharedAlbums.addByHand(entry, context: context)
        all = await Task.detached { SharedAlbums.Logged.load() }.value
    }
}
