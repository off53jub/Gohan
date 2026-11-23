import SwiftData
import SwiftUI

/// きろく（新しい順。月の扉と日ごとのカード）
struct TimelineView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Meal> { !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var scanner = Scanner.shared
    @State private var router = Router.shared
    @State private var path = NavigationPath()
    @State private var sheet: Sheet?
    @AppStorage("timeline.last") private var lastSeen = ""
    @AppStorage("show.small") private var showSmall = true

    enum Sheet: String, Identifiable {
        case search, settings, review, two, stats, calendar
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        StatusLine()
                        if let past = oneYearAgo {
                            OneYearCard(meal: past) { path.append(past) }
                        }
                        if checkCount > 0 {
                            Button { sheet = .review } label: {
                                Text("「たぶん」が \(checkCount) 件あります（見なくても大丈夫です）")
                                    .font(.footnote).foregroundStyle(Ink.hai).underline(pattern: .dot)
                            }
                            .frame(minHeight: 32)
                        }
                        ForEach(months) { month in
                            MonthDoor(month: month) { sheet = .calendar }
                                .id("month-\(month.id)")
                            ForEach(month.days) { day in
                                DayBlock(day: day, trips: trips, open: { path.append($0) })
                            }
                        }
                        if meals.isEmpty && !scanner.isRunning {
                            EmptyArt(title: "まだ記録がありません",
                                     message: "ごはんの写真を撮ると、ここに並びます。\n下に引くと読み直します。")
                        }
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, 20)
                }
                .background(Ink.ground)
                .refreshable { await scanner.scan() }
                .onAppear {
                    // 前に見ていた所から（便71）
                    if !lastSeen.isEmpty, let id = UUID(uuidString: lastSeen), meals.contains(where: { $0.id == id }) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                    ThumbCache.shared.prefetch(meals.prefix(12).compactMap { $0.photoIDs.first }, side: 800)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("ごはん帖").font(.brush(26, relativeTo: .title)).foregroundStyle(Ink.ai)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            ForEach(months) { month in
                                Button(month.title) { withAnimation { proxy.scrollTo("month-\(month.id)", anchor: .top) } }
                            }
                        } label: {
                            Image(systemName: "calendar").accessibilityLabel("月へ飛ぶ")
                        }
                        Button { sheet = .search } label: {
                            Image(systemName: "magnifyingglass").accessibilityLabel("さがす")
                        }
                        Menu {
                            Button { sheet = .calendar } label: { Label("カレンダーで見る", systemImage: "calendar") }
                            Button { sheet = .stats } label: { Label("数える・まとめ", systemImage: "chart.bar") }
                            Button { sheet = .review } label: { Label("「たぶん」を見る", systemImage: "questionmark.circle") }
                            Button { sheet = .two } label: { Label("ふたり", systemImage: "person.2") }
                            Button { sheet = .settings } label: { Label("設定", systemImage: "gearshape") }
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel("ほかのこと")
                        }
                    }
                }
            }
            .toolbarBackground(Ink.ground, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Meal.self) { meal in
                MealDetailView(meal: meal).onAppear { lastSeen = meal.id.uuidString }
            }
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .search: SearchView(initial: router.searchQuery ?? "")
            case .settings: SettingsView()
            case .review: ReviewView()
            case .two: TwoView()
            case .stats: StatsView()
            case .calendar: CalendarView()
            }
        }
        .onChange(of: router.openMeal) { _, id in openMeal(id) }
        .onChange(of: router.searchQuery) { _, q in if q != nil { sheet = .search } }
        .onChange(of: router.showOneYear) { _, show in
            if show, let past = oneYearAgo { path.append(past) }
            router.showOneYear = false
        }
        .onAppear { openMeal(router.openMeal) }
    }

    private func openMeal(_ id: UUID?) {
        guard let id else { return }
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == id })
        if let meal = try? context.fetch(descriptor).first { path.append(meal) }
        router.openMeal = nil
    }

    private var shown: [Meal] {
        showSmall ? meals : meals.filter { $0.kind == "meal" || $0.kind == "cafe" }
    }

    private var checkCount: Int { meals.filter(\.needsCheck).count }

    /// 1年前の今日（前後 3 日まで。便28）
    private var oneYearAgo: Meal? {
        guard let target = Calendar.current.date(byAdding: .year, value: -1, to: Date()) else { return nil }
        let near = meals.filter { abs($0.date.timeIntervalSince(target)) <= 3 * 86_400 }
        return near.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }

    private var trips: [Matcher.TripSpan] {
        let home = Spots.get("home").map { (latitude: $0.latitude, longitude: $0.longitude) }
        let input = meals.prefix(800).map { Matcher.TripInput(id: $0.id, date: $0.date, latitude: $0.latitude, longitude: $0.longitude, region: $0.region) }
        return Matcher.trips(Array(input), home: home)
    }

    private var months: [MonthGroup] { MonthGroup.make(shown) }
}

/// 月ごと・日ごとのまとまり
struct MonthGroup: Identifiable {
    let id: String
    let title: String
    var days: [DayGroup]
    var meals: [Meal] { days.flatMap(\.meals) }

    static func make(_ meals: [Meal]) -> [MonthGroup] {
        let calendar = Calendar.current
        var out: [MonthGroup] = []
        for meal in meals {
            let parts = calendar.dateComponents([.year, .month], from: meal.date)
            let id = "\(parts.year ?? 0)-\(parts.month ?? 0)"
            let thisYear = calendar.component(.year, from: Date()) == parts.year
            let title = thisYear ? "\(parts.month ?? 0)月" : "\(parts.year ?? 0)年\(parts.month ?? 0)月"
            let day = calendar.startOfDay(for: meal.date)
            if out.last?.id != id { out.append(MonthGroup(id: id, title: title, days: [])) }
            if out[out.count - 1].days.last?.day == day {
                out[out.count - 1].days[out[out.count - 1].days.count - 1].meals.append(meal)
            } else {
                out[out.count - 1].days.append(DayGroup(day: day, meals: [meal]))
            }
        }
        return out
    }
}

struct DayGroup: Identifiable {
    let day: Date
    var meals: [Meal]
    var id: Date { day }

    var label: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "d日 EEEE"
        if Calendar.current.isDateInToday(day) { return "今日 " + f.string(from: day) }
        if Calendar.current.isDateInYesterday(day) { return "きのう " + f.string(from: day) }
        return f.string(from: day)
    }
}

/// 月の扉（「11月　12食・8軒・はじめて3軒」と十草の帯。デ4・便29）
struct MonthDoor: View {
    let month: MonthGroup
    let more: () -> Void

    var body: some View {
        let meals = month.meals
        let places = Set(meals.compactMap { $0.place?.key })
        let firsts = meals.filter { $0.place != nil && $0.visitNumber == 1 }.count
        Button(action: more) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(month.title).font(.brush(32, relativeTo: .largeTitle)).foregroundStyle(Ink.ai)
                    Spacer()
                    Text("\(meals.count)食・\(places.count)軒・はじめて\(firsts)軒")
                        .font(.footnote).foregroundStyle(Ink.hai)
                }
                Tokusa()
            }
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(month.title)。\(meals.count)食、\(places.count)軒、はじめて\(firsts)軒")
    }
}

/// 1日分のカード
struct DayBlock: View {
    let day: DayGroup
    let trips: [Matcher.TripSpan]
    let open: (Meal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trip = tripStarting {
                TripHeader(trip: trip)
            }
            Text(day.label).font(.system(.footnote, weight: .bold)).foregroundStyle(Ink.hai)
            ForEach(day.meals) { meal in
                MealCard(meal: meal) { open(meal) }
                    .id(meal.id)
            }
        }
    }

    /// 旅行の最後の日（新しい順に並ぶので、旅行の見出しはここに出す。便20）
    private var tripStarting: Matcher.TripSpan? {
        trips.first { trip in day.meals.contains { $0.id == trip.mealIDs.last } }
    }
}

struct TripHeader: View {
    let trip: Matcher.TripSpan

    var body: some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d"
        return HStack(spacing: 10) {
            Image(systemName: "suitcase").foregroundStyle(Ink.ai)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.region.isEmpty ? "旅のごはん" : "\(trip.region)のごはん")
                    .font(.brush(20, relativeTo: .title3)).foregroundStyle(Ink.ai)
                Text("\(f.string(from: trip.start))〜\(f.string(from: trip.end))・\(trip.mealIDs.count)食")
                    .font(.caption).foregroundStyle(Ink.hai)
            }
            Spacer()
        }
        .padding(14)
        .card(radius: 16)
    }
}

/// 読み込みの様子と、AI の状態（便10）
struct StatusLine: View {
    @State private var scanner = Scanner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if scanner.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(scanner.status.isEmpty ? "写真を読んでいます" : scanner.status)
                        .font(.footnote).foregroundStyle(Ink.hai)
                }
            }
            if let error = scanner.lastError {
                Text(error).font(.footnote).foregroundStyle(Ink.hai)
            }
            if !ClaudeLink.isReady || !Spend.canSpend {
                Text(AISettings.deviceOnly ? "端末だけで判定しています（写真は送りません）"
                     : Spend.canSpend ? "いまは端末だけで判定しています" : "今月の AI はお休み中です。端末だけで判定しています")
                    .font(.footnote).foregroundStyle(Ink.hai)
            }
            if scanner.deferredOld > 0 {
                Text("古い写真 \(scanner.deferredOld) 枚は、充電中に Wi-Fi で読みます")
                    .font(.footnote).foregroundStyle(Ink.hai)
            }
        }
    }
}

/// 1年前の今日（便28）
struct OneYearCard: View {
    let meal: Meal
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                PhotoThumb(id: meal.photoIDs.first, side: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text("1年前の今日").font(.system(.caption, weight: .medium)).foregroundStyle(Ink.hai)
                    Text(meal.title).font(.brush(16, relativeTo: .headline)).foregroundStyle(Ink.ai).lineLimit(1)
                    Text(meal.dishText).font(.footnote).foregroundStyle(Ink.hai).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Ink.hai)
            }
            .padding(10)
            .card(radius: 16)
        }
        .buttonStyle(.plain)
    }
}

/// 食事のカード（写真の組み・はんこ・ハート・札。デ3・デ5・デ6・デ7・便36・便40・便66）
struct MealCard: View {
    @Bindable var meal: Meal
    let open: () -> Void
    @Environment(\.modelContext) private var context
    @State private var heartBurst = false
    @State private var sharing: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Collage(ids: Array(meal.photoIDs.prefix(3)))
                if meal.visitNumber >= 2 {
                    Stamp(text: "\(meal.visitNumber)回目").padding(12)
                }
                if heartBurst {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 200)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    Text(meal.title).font(.brush(20, relativeTo: .title3)).foregroundStyle(Ink.ai).lineLimit(2)
                    if meal.special { Chip(text: "記念日") }
                    Spacer(minLength: 4)
                    if let place = meal.place {
                        HeartButton(on: place.wantAgain) { toggleWant(place) }
                    }
                }
                HStack(spacing: 8) {
                    Chip(text: meal.genre)
                    Text(meal.dishes.isEmpty ? (meal.summary.isEmpty ? " " : meal.summary) : meal.dishes.joined(separator: "、"))
                        .font(.subheadline).foregroundStyle(Ink.sumi).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(meta).font(.footnote).foregroundStyle(Ink.hai)
                    if meal.needsCheck {
                        Text("・たぶん").font(.footnote).foregroundStyle(Ink.hai).underline(pattern: .dot)
                    }
                    if let mark = meal.visitMark {
                        Text("・\(mark)").font(.footnote.bold()).foregroundStyle(Ink.aka)
                    }
                    if !meal.reactions.isEmpty {
                        Text("・\(meal.reactions.joined())").font(.footnote).foregroundStyle(Ink.aka)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 12)
        }
        .card()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { doubleTap() }
        .onTapGesture { open() }
        .sensoryFeedback(.impact(weight: .medium), trigger: heartBurst)
        .contextMenu {
            if let place = meal.place {
                Button { toggleWant(place) } label: {
                    Label(place.wantAgain ? "また行きたいを外す" : "また行きたい", systemImage: place.wantAgain ? "heart.slash" : "heart")
                }
            }
            Button { meal.special.toggle() } label: {
                Label(meal.special ? "記念日の印を外す" : "記念日のごはん", systemImage: "sparkles")
            }
            Button(role: .destructive) { MealActions.hide(meal, context: context) } label: {
                Label("ごはんじゃない", systemImage: "eye.slash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "また行きたい") { if let place = meal.place { toggleWant(place) } }
    }

    private var meta: String {
        let time = meal.date.formatted(.dateTime.hour().minute())
        var parts = [meal.area, time].filter { !$0.isEmpty }
        if let kind = meal.kindLabel { parts.append(kind) }
        return parts.joined(separator: "・")
    }

    private func toggleWant(_ place: Place) {
        place.wantAgain.toggle()
        try? context.save()
    }

    /// 写真を2回たたくとハート（便40）
    private func doubleTap() {
        guard let place = meal.place else { return }
        if !place.wantAgain { place.wantAgain = true; try? context.save() }
        withAnimation(.spring(duration: 0.25)) { heartBurst = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation { heartBurst = false }
        }
    }
}

/// 食事への操作（消す・戻す）。どの画面からも同じにする
enum MealActions {
    @MainActor
    static func hide(_ meal: Meal, context: ModelContext) {
        meal.hidden = true
        try? context.save()
        Spotlight.remove([meal.id])
        Metrics.count("hidden")
        UndoCenter.shared.offer("一覧から外しました") {
            meal.hidden = false
            try? context.save()
            Spotlight.index([meal])
        }
    }
}
