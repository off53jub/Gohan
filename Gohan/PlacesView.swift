import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// また行きたい（今日のおすすめ・並べ方・しぼり込み・行ってみたい。デ12・便42・便43・便48）
struct WantView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Place> { $0.wantAgain || $0.wantToTry }) private var places: [Place]
    @State private var router = Router.shared
    @State private var path = NavigationPath()
    @State private var here: CLLocation?
    @State private var sort = Sort.near
    @State private var filter = Filter.all
    @State private var adding = false
    @State private var locating = false

    enum Sort: String, CaseIterable { case near = "近い順", away = "ごぶさた順", genre = "ジャンル" }
    enum Filter: String, CaseIterable { case all = "すべて", close = "近く", cafe = "カフェ", been = "行ったことがある", notYet = "行ってみたい" }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let pick = todayPick {
                        TodayPickCard(place: pick, distance: distance(pick)) { path.append(pick) }
                    } else if here == nil, !places.isEmpty {
                        Button(locating ? "いまいる所を調べています…" : "いまいる所から、今日の1軒を選ぶ") { Task { await locate() } }
                            .buttonStyle(InkButtonStyle(filled: false))
                            .disabled(locating)
                    }
                    Picker("並べ方", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Filter.allCases, id: \.self) { f in
                                Button { filter = f } label: { Chip(text: f.rawValue, strong: filter == f) }
                                    .buttonStyle(.plain)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    ForEach(shown) { place in
                        WantRow(place: place, distance: distance(place)) { path.append(place) }
                    }
                    if places.isEmpty {
                        EmptyArt(title: "また行きたいお店はまだありません",
                                 message: "記録のハートを押すか、右上の「＋」で行ってみたいお店を足せます。")
                    }
                    NavigationLink("行ったお店ぜんぶを見る") { PlacesListView() }
                        .font(.subheadline).foregroundStyle(Ink.ai)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
            }
            .background(Ink.ground)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus").accessibilityLabel("行ってみたいお店を足す") }
                }
            }
            .toolbarBackground(Ink.ground, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .sheet(isPresented: $adding) { AddWishView() }
            .task {
                if LocationWatch.shared.status == .authorizedWhenInUse || LocationWatch.shared.status == .authorizedAlways {
                    await locate()
                }
            }
            .onChange(of: router.openPlace) { _, key in openPlace(key) }
            .onAppear { openPlace(router.openPlace) }
        }
    }

    private func openPlace(_ key: String?) {
        guard let key else { return }
        if let place = places.first(where: { $0.key == key }) { path.append(place) }
        router.openPlace = nil
    }

    private func locate() async {
        locating = true
        here = await LocationWatch.shared.current()
        locating = false
    }

    private func distance(_ place: Place) -> Double? {
        here.map { $0.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) }
    }

    private func daysSince(_ place: Place) -> Double? {
        place.lastVisit.map { -$0.timeIntervalSinceNow / 86_400 }
    }

    /// 近いほど・ごぶさたなほど上（便42）
    private var todayPick: Place? {
        guard here != nil else { return nil }
        return places
            .filter { !$0.maybeClosed && (distance($0) ?? .infinity) < 20_000 }
            .max { a, b in
                Matcher.pickScore(distance: distance(a), daysSince: daysSince(a), notYet: a.notYet)
                    < Matcher.pickScore(distance: distance(b), daysSince: daysSince(b), notYet: b.notYet)
            }
    }

    private var shown: [Place] {
        let filtered = places.filter { p in
            switch filter {
            case .all: true
            case .close: (distance(p) ?? .infinity) <= 2_000
            case .cafe: ["カフェ", "スイーツ", "パン"].contains(p.mainGenre)
            case .been: !p.notYet
            case .notYet: p.notYet
            }
        }
        switch sort {
        case .near:
            return filtered.sorted { (distance($0) ?? .infinity) < (distance($1) ?? .infinity) }
        case .away:
            return filtered.sorted { ($0.lastVisit ?? .distantPast) < ($1.lastVisit ?? .distantPast) }
        case .genre:
            return filtered.sorted { ($0.mainGenre, $0.name) < ($1.mainGenre, $1.name) }
        }
    }
}

struct TodayPickCard: View {
    let place: Place
    let distance: Double?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Collage(ids: Array(place.visibleMeals.prefix(1).compactMap { $0.photoIDs.first }), height: 150)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(walkText).font(.caption).foregroundStyle(Ink.onAi.opacity(0.85))
                    Text(place.name).font(.brush(20, relativeTo: .title3)).foregroundStyle(Ink.onAi).lineLimit(2)
                    Text(sub).font(.footnote).foregroundStyle(Ink.onAi.opacity(0.85))
                }
                Spacer()
                Button("道を見る") { PlaceFinder.directions(name: place.name, latitude: place.latitude, longitude: place.longitude) }
                    .font(.subheadline.bold())
                    .foregroundStyle(Ink.ai)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Ink.onAi, in: Capsule())
            }
            .padding(16)
        }
        .background(Ink.ai, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日のおすすめ、\(place.name)。\(walkText)")
    }

    private var walkText: String {
        guard let distance else { return "今日のおすすめ" }
        let minutes = max(1, Int(distance / 80))
        return minutes <= 30 ? "いまいる所から歩いて\(minutes)分" : "いまいる所から \(String(format: "%.1f", distance / 1000))km"
    }

    private var sub: String {
        var parts = [place.mainGenre].filter { !$0.isEmpty }
        if let last = place.lastVisit {
            parts.append("最後は\(Self.ago(last))")
        } else {
            parts.append("まだ行っていない")
        }
        return parts.joined(separator: "・")
    }

    static func ago(_ date: Date) -> String {
        let days = Int(-date.timeIntervalSinceNow / 86_400)
        if days < 1 { return "今日" }
        if days < 2 { return "きのう" }
        if days < 30 { return "\(days)日前" }
        if days < 365 { return "\(days / 30)か月前" }
        return "\(days / 365)年前"
    }
}

struct WantRow: View {
    let place: Place
    let distance: Double?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if place.notYet {
                Text("これから")
                    .font(.caption.bold()).foregroundStyle(Ink.hai)
                    .frame(width: 68, height: 68)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hai, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
            } else {
                PhotoThumb(id: place.visibleMeals.first?.photoIDs.first, side: 68)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.brush(17, relativeTo: .headline)).foregroundStyle(Ink.ai).lineLimit(1)
                Text([place.mainGenre, place.address].filter { !$0.isEmpty }.joined(separator: "・"))
                    .font(.footnote).foregroundStyle(Ink.sumi).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(place.maybeClosed ? Ink.aka : Ink.hai).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                PlaceFinder.directions(name: place.name, latitude: place.latitude, longitude: place.longitude)
            } label: {
                Image(systemName: "mappin.and.ellipse").font(.title3).foregroundStyle(Ink.ai).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(place.name) への道を見る")
        }
        .padding(10)
        .card(radius: 16)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private var detail: String {
        var parts: [String] = []
        if let distance { parts.append(distance < 1000 ? "\(Int(distance))m" : String(format: "%.1fkm", distance / 1000)) }
        if place.maybeClosed { parts.append("閉店したかも") }
        if let last = place.lastVisit {
            parts.append("\(place.visibleMeals.count)回・最後は\(TodayPickCard.ago(last))")
        } else {
            parts.append("行ってみたい" + (place.savedFrom.isEmpty ? "" : "（\(place.savedFrom)）"))
        }
        return parts.joined(separator: "・")
    }
}

/// 行ったお店ぜんぶ（さがす・しぼる）
struct PlacesListView: View {
    @Query(sort: \Place.firstVisit, order: .reverse) private var places: [Place]
    @State private var query = ""

    var body: some View {
        List {
            ForEach(shown) { place in
                NavigationLink(value: place) {
                    HStack(spacing: 12) {
                        PhotoThumb(id: place.visibleMeals.first?.photoIDs.first, side: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(place.name).font(.headline).foregroundStyle(Ink.ai).lineLimit(1)
                                if place.wantAgain { Image(systemName: "heart.fill").foregroundStyle(Ink.aka).font(.caption) }
                            }
                            Text("\(place.mainGenre)・\(place.visibleMeals.count)回").font(.caption).foregroundStyle(Ink.hai)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "お店・料理・ジャンル")
        .navigationTitle("行ったお店（\(shown.count)）")
    }

    private var shown: [Place] {
        places
            .filter { !$0.visibleMeals.isEmpty }
            .filter { p in
                query.isEmpty || p.name.localizedStandardContains(query) || p.address.localizedStandardContains(query)
                    || p.visibleMeals.contains { $0.genre.localizedStandardContains(query) || $0.dishes.contains { $0.localizedStandardContains(query) } }
            }
            .sorted { ($0.lastVisit ?? $0.firstVisit) > ($1.lastVisit ?? $1.firstVisit) }
    }
}

/// お店1つ（デ11・便44〜47）
struct PlaceDetailView: View {
    @Bindable var place: Place
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var shareImage: Image?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Collage(ids: place.visibleMeals.prefix(3).compactMap { $0.photoIDs.first }, height: 230)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(place.name).font(.brush(26, relativeTo: .title)).foregroundStyle(Ink.ai)
                            Text([place.mainGenre, place.address].filter { !$0.isEmpty }.joined(separator: "・"))
                                .font(.footnote).foregroundStyle(Ink.hai)
                            if place.fromGoogle { GoogleCredit() }
                        }
                        Spacer()
                        HeartButton(on: place.wantAgain, size: 24) {
                            place.wantAgain.toggle()
                            try? context.save()
                        }
                        .overlay(Circle().strokeBorder(place.wantAgain ? Ink.aka : Ink.line, lineWidth: 2))
                    }
                    if place.maybeClosed {
                        Label("マップで見つからなくなりました。閉店したかもしれません。", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(Ink.aka)
                    }
                    stamps
                    dishesEaten
                    VStack(alignment: .leading, spacing: 6) {
                        Text("つぎに食べたいもの").sectionLabel()
                        TextField("例: まぜそば", text: $place.nextWish)
                            .font(.body)
                            .padding(12)
                            .background(Ink.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("メモ").sectionLabel()
                        TextField("だれと行きたい・予約のこと など", text: $place.note, axis: .vertical)
                            .padding(12)
                            .background(Ink.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
                    }
                    buttons
                    links
                    visits
                }
                .padding(20)
            }
        }
        .background(Ink.ground)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            shareImage = await ShareCards.placeImage(place)
            if place.phone.isEmpty, let phone = await PlaceFinder.phone(name: place.name, latitude: place.latitude, longitude: place.longitude) {
                place.phone = phone
            }
        }
    }

    /// 来た日のはんこ（デ5）
    private var stamps: some View {
        let visits = place.visibleMeals.reversed().map { $0 }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("来た日").sectionLabel()
                Spacer()
                if let first = visits.first {
                    Text("はじめては \(first.date.formatted(.dateTime.year().month().day()))").font(.caption).foregroundStyle(Ink.hai)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(visits.enumerated()), id: \.element.id) { i, meal in
                        NavigationLink(value: meal) {
                            Stamp(text: meal.date.formatted(.dateTime.month(.defaultDigits).day()), sub: "\(i + 1)回目", size: 64,
                                  filled: i == visits.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                    NextStamp(size: 64)
                }
                .padding(4)
            }
        }
        .padding(16)
        .card()
    }

    @ViewBuilder
    private var dishesEaten: some View {
        let dishes = Array(Set(place.visibleMeals.flatMap(\.dishes))).sorted()
        if !dishes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("これまで食べたもの").sectionLabel()
                FlowRow(spacing: 8) { ForEach(dishes, id: \.self) { Chip(text: $0) } }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                PlaceFinder.directions(name: place.name, latitude: place.latitude, longitude: place.longitude)
            } label: {
                Label("道を見る", systemImage: "mappin.and.ellipse")
            }
            .buttonStyle(InkButtonStyle())
            Button {
                let digits = place.phone.filter { $0.isNumber || $0 == "+" }
                if let url = URL(string: "tel:\(digits)") { openURL(url) }
            } label: {
                Label("電話", systemImage: "phone")
            }
            .buttonStyle(InkButtonStyle(filled: false))
            .disabled(place.phone.isEmpty)
            if let shareImage {
                ShareLink(item: shareImage, preview: SharePreview(place.name, image: shareImage)) {
                    Label("送る", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(InkButtonStyle(filled: false))
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private var links: some View {
        HStack(spacing: 16) {
            if let url = PlaceFinder.tabelogURL(name: place.name) {
                Link("食べログで開く", destination: url)
            }
            if let url = PlaceFinder.googleMapsURL(name: place.name, address: place.address) {
                Link("Google マップで開く", destination: url)
            }
        }
        .font(.footnote)
        .foregroundStyle(Ink.ai)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var visits: some View {
        if !place.visibleMeals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("行った記録（\(place.visibleMeals.count)回）").sectionLabel()
                ForEach(place.visibleMeals) { meal in
                    NavigationLink(value: meal) {
                        HStack(spacing: 12) {
                            PhotoThumb(id: meal.photoIDs.first, side: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meal.date.formatted(.dateTime.year().month().day().weekday())).font(.caption).foregroundStyle(Ink.hai)
                                Text(meal.dishText).foregroundStyle(Ink.sumi).lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .card(radius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 行ったお店の地図（丸い写真のピン。また行きたいお店は赤いふち。デ13・便64）
struct PlacesMapView: View {
    @Query private var places: [Place]
    @State private var onlyWant = false
    @State private var selected: Place?
    @State private var partner = PartnerStore.shared
    @State private var showTogether = false

    var body: some View {
        NavigationStack {
            Map {
                ForEach(shown) { place in
                    Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) {
                        Button { selected = place } label: {
                            PhotoThumb(id: place.visibleMeals.first?.photoIDs.first, side: 40, circle: true)
                                .overlay(Circle().strokeBorder(place.wantAgain ? Ink.aka : Color.white, lineWidth: 3))
                                .shadow(radius: 2)
                        }
                        .accessibilityLabel(place.name)
                    }
                }
                ForEach(partnerPins) { m in
                    Annotation(m.title, coordinate: CLLocationCoordinate2D(latitude: m.latitude ?? 0, longitude: m.longitude ?? 0)) {
                        Circle().fill(Ink.aka.opacity(0.8)).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Picker("表示", selection: $onlyWant) {
                        Text("すべて").tag(false)
                        Text("また行きたい").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if partner.book != nil {
                        Toggle("ふたり", isOn: $showTogether).toggleStyle(.button).tint(Ink.aka)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.thinMaterial)
            }
            .navigationTitle("地図")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { PlaceDetailView(place: $0) }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
        }
    }

    private var shown: [Place] {
        places.filter { (!$0.visibleMeals.isEmpty || $0.wantAgain || $0.wantToTry) && (!onlyWant || $0.wantAgain) }
    }

    /// ふたり帖の相手の食事（ふたりの地図。便64）
    private var partnerPins: [PartnerMeal] {
        guard showTogether, let book = partner.book else { return [] }
        return book.meals.filter { $0.latitude != nil }
    }
}

/// 行ってみたいお店を足す（インスタ・マップ・食べログのリンクや文を貼る・名前で探す。便43）
struct AddWishView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [PlaceCandidate] = []
    @State private var working = false
    @State private var message: String?
    @State private var source = "名前で"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard let first = strings.first else { return }
                        Task { @MainActor in
                            text = first
                            await find()
                        }
                    }
                    .tint(Ink.ai)
                    TextField("お店の名前・リンク・投稿の文", text: $text, axis: .vertical)
                        .onSubmit { Task { await find() } }
                    Button("探す") { Task { await find() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                } footer: {
                    Text("インスタ・Google マップ・食べログで「共有 → コピー」したものを貼れます。")
                }
                if working { Section { ProgressView() } }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(Ink.hai) } }
                if !results.isEmpty {
                    Section("どのお店ですか") {
                        ForEach(results) { c in
                            Button { save(c) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).foregroundStyle(Ink.sumi)
                                    Text(c.address).font(.caption).foregroundStyle(Ink.hai)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("行ってみたいお店")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func find() async {
        working = true
        message = nil
        defer { working = false }
        let guess = await WishReader.read(text)
        source = guess.source
        let here = await LocationWatch.shared.current()
        let lat = guess.latitude ?? here?.coordinate.latitude ?? 35.681
        let lon = guess.longitude ?? here?.coordinate.longitude ?? 139.767
        let radius = guess.latitude != nil ? 1_000.0 : (here != nil ? 30_000.0 : 80_000.0)
        results = await PlaceFinder.search(guess.query, latitude: lat, longitude: lon, radius: radius)
        if results.isEmpty { message = "「\(guess.query)」で見つかりませんでした。お店の名前と街の名前で探してみてください。" }
    }

    private func save(_ c: PlaceCandidate) {
        let place = PlaceBook.place(for: c, date: Date(), context: context)
        place.wantAgain = true
        if place.notYet {
            place.wantToTry = true
            place.savedFrom = source
        }
        try? context.save()
        dismiss()
    }
}

/// 貼られたものから、お店の名前と場所を読む（便43）
enum WishReader {
    struct Guess {
        var query: String
        var latitude: Double?
        var longitude: Double?
        var source: String
    }

    static func read(_ raw: String) async -> Guess {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let url = detector?.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))?.url
        if let url, let host = url.host {
            if host.contains("tabelog") {
                if let title = await pageTitle(url) {
                    let name = title.components(separatedBy: " - ").first?.components(separatedBy: " (").first ?? title
                    return Guess(query: name, source: "食べログ")
                }
            }
            if host.contains("goo.gl") || host.contains("google") {
                if let final = await finalURL(url), let guess = googlePlace(final) { return guess }
            }
            if host.contains("apple.com"), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let q = c.queryItems?.first { $0.name == "q" }?.value
                let ll = c.queryItems?.first { $0.name == "ll" }?.value?.split(separator: ",").compactMap { Double($0) }
                if let q { return Guess(query: q, latitude: ll?.first, longitude: ll?.last, source: "マップ") }
            }
        }
        // インスタの投稿の文などは、AI に店名を読んでもらう（使えるときだけ）
        let isInsta = url?.host?.contains("instagram") == true
        let body = text.replacingOccurrences(of: url?.absoluteString ?? "\u{0}", with: "")
        if ClaudeLink.isReady, body.count >= 6 || isInsta {
            if let name = try? await askName(body.isEmpty ? text : body) {
                return Guess(query: name, source: isInsta ? "インスタ" : "貼った文")
            }
        }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? text
        return Guess(query: firstLine.trimmingCharacters(in: .whitespaces), source: isInsta ? "インスタ" : "名前で")
    }

    private static func pageTitle(_ url: URL) async -> String? {
        guard let result = try? await URLSession.shared.data(from: url) else { return nil }
        let html = String(decoding: result.0.prefix(200_000), as: UTF8.self)
        guard let start = html.range(of: "<title>"), let end = html.range(of: "</title>", range: start.upperBound..<html.endIndex) else { return nil }
        return String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func finalURL(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        return result.1.url
    }

    /// https://www.google.com/maps/place/店名/@35.6,139.7,17z → 店名と位置
    static func googlePlace(_ url: URL) -> Guess? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "place"), i + 1 < parts.count else { return nil }
        let name = (parts[i + 1].removingPercentEncoding ?? parts[i + 1]).replacingOccurrences(of: "+", with: " ")
        var lat: Double?, lon: Double?
        if let at = parts.first(where: { $0.hasPrefix("@") }) {
            let nums = at.dropFirst().split(separator: ",").compactMap { Double($0) }
            if nums.count >= 2 { lat = nums[0]; lon = nums[1] }
        }
        return Guess(query: name, latitude: lat, longitude: lon, source: "Google マップ")
    }

    private static func askName(_ text: String) async throws -> String? {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["name": ["type": "string"], "area": ["type": "string"]],
            "required": ["name", "area"],
            "additionalProperties": false,
        ]
        let data = try await ClaudeLink.ask(
            system: "貼られた文（SNS の投稿など）から、紹介されている飲食店の名前と、街の名前を読み取ります。分からなければ空にします。",
            text: String(text.prefix(2000)), schema: schema)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        guard let name = json?["name"], !name.isEmpty else { return nil }
        let area = json?["area"] ?? ""
        return area.isEmpty ? name : "\(name) \(area)"
    }
}
