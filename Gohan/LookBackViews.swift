import SwiftData
import SwiftUI

/// さがす（料理・お店・街・ジャンル・月。ことばで探す。便31・便32・便34）
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Meal> { !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State var initial: String
    @State private var query = ""
    @State private var aiFilter: SmartFilter?
    @State private var asking = false
    @State private var aiError: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty && aiFilter == nil {
                    Section("ジャンルの棚") { shelf(genres) }
                    Section("街の棚") { shelf(areas) }
                } else {
                    if ClaudeLink.isReady, query.count >= 4 {
                        Section {
                            Button {
                                Task { await askAI() }
                            } label: {
                                Label(asking ? "AI が考えています…" : "「\(query)」を AI でさがす", systemImage: "sparkles")
                            }
                            .disabled(asking)
                            if let aiError { Text(aiError).font(.footnote).foregroundStyle(Ink.hai) }
                            if let aiFilter { Text(aiFilter.explain).font(.footnote).foregroundStyle(Ink.hai) }
                        } footer: {
                            Text("例:「去年の夏の冷やし中華」「渋谷で行ったカフェ」")
                        }
                    }
                    Section("見つかった食事（\(results.count)）") {
                        ForEach(results.prefix(200)) { meal in
                            NavigationLink(value: meal) { SearchRow(meal: meal) }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "料理・お店・街・ジャンル・月")
            .onChange(of: query) { _, _ in aiFilter = nil; aiError = nil }
            .navigationTitle("さがす")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
            .onAppear {
                if !initial.isEmpty { query = initial; initial = "" }
                Router.shared.searchQuery = nil
            }
        }
    }

    private func shelf(_ items: [CountRow]) -> some View {
        FlowRow(spacing: 8) {
            ForEach(items) { item in
                Button { query = item.name } label: { Chip(text: "\(item.name) \(item.count)") }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var genres: [CountRow] { CountRow.make(meals.map(\.genre)) }

    private var areas: [CountRow] { Array(CountRow.make(meals.map(\.area).filter { !$0.isEmpty }).prefix(30)) }

    private var results: [Meal] {
        if let aiFilter { return meals.filter(aiFilter.matches) }
        let words = query.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        return meals.filter { meal in
            words.allSatisfy { w in Self.text(of: meal).localizedStandardContains(w) || Self.dishKeyHit(meal, w) }
        }
    }

    static func text(of meal: Meal) -> String {
        let month = "\(Calendar.current.component(.year, from: meal.date))年\(Calendar.current.component(.month, from: meal.date))月"
        return [meal.title, meal.place?.address ?? "", meal.area, meal.region, meal.genre, meal.dishes.joined(separator: " "),
                meal.note, meal.summary, month, meal.special ? "記念日" : ""].joined(separator: " ")
    }

    /// らーめん で ラーメン も見つかる（便27）
    static func dishKeyHit(_ meal: Meal, _ word: String) -> Bool {
        let key = Matcher.dishKey(word)
        guard key.count >= 2 else { return false }
        return meal.dishes.contains { Matcher.dishKey($0).contains(key) }
    }

    private func askAI() async {
        asking = true
        aiError = nil
        defer { asking = false }
        do {
            aiFilter = try await SmartFilter.ask(query)
        } catch {
            aiError = error.localizedDescription
        }
    }
}

struct SearchRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumb(id: meal.photoIDs.first, side: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.title).font(.headline).foregroundStyle(Ink.ai).lineLimit(1)
                Text(meal.dishText).font(.subheadline).foregroundStyle(Ink.sumi).lineLimit(1)
                Text(meal.date.formatted(.dateTime.year().month().day())).font(.caption).foregroundStyle(Ink.hai)
            }
        }
    }
}

/// ことばを、さがす条件に変える（便32）
struct SmartFilter {
    var words: [String]
    var genres: [String]
    var from: Date?
    var to: Date?
    var wantOnly: Bool
    var explain: String

    func matches(_ meal: Meal) -> Bool {
        if let from, meal.date < from { return false }
        if let to, meal.date > to { return false }
        if wantOnly, meal.place?.wantAgain != true { return false }
        if !genres.isEmpty, !genres.contains(meal.genre) { return false }
        let text = SearchView.text(of: meal)
        return words.allSatisfy { text.localizedStandardContains($0) || SearchView.dishKeyHit(meal, $0) }
    }

    static func ask(_ question: String) async throws -> SmartFilter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "words": ["type": "array", "items": ["type": "string"]],
                "genres": ["type": "array", "items": ["type": "string", "enum": Genre.all]],
                "from": ["type": "string"],
                "to": ["type": "string"],
                "want_only": ["type": "boolean"],
                "explain": ["type": "string"],
            ],
            "required": ["words", "genres", "from", "to", "want_only", "explain"],
            "additionalProperties": false,
        ]
        let system = """
        食事の記録を探す条件を作ります。記録には 店名・住所・街・都道府県・ジャンル・料理名・メモ があります。
        words は記録の文字に含まれていてほしい短いことば（料理名・店名・街の名前など。言い換えずに、記録に出てきそうな形で）。
        genres は当てはまるジャンル（無ければ空）。from・to は yyyy-MM-dd（無ければ空）。季節は日本の季節で考える。
        want_only は「また行きたい」お店だけのとき true。explain は作った条件を20字くらいで。
        今日は \(f.string(from: Date())) です。
        """
        let data = try await ClaudeLink.ask(system: system, text: question, schema: schema)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClaudeError.unreadable }
        let end = (json["to"] as? String).flatMap { f.date(from: $0) }.map { $0.addingTimeInterval(86_399) }
        return SmartFilter(words: json["words"] as? [String] ?? [], genres: json["genres"] as? [String] ?? [],
                           from: (json["from"] as? String).flatMap { f.date(from: $0) }, to: end,
                           wantOnly: json["want_only"] as? Bool ?? false, explain: json["explain"] as? String ?? "")
    }
}

/// 数えた1行（ゆれる書き方は1つにまとめる）
struct CountRow: Identifiable {
    let name: String
    let count: Int
    var id: String { name }

    static func make(_ items: [String]) -> [CountRow] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for item in items {
            let k = Matcher.dishKey(item)
            let key = k.isEmpty ? item : k
            if names[key] == nil { names[key] = item }
            counts[key, default: 0] += 1
        }
        return counts.map { CountRow(name: names[$0.key] ?? $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }
}

/// 数える・まとめ（便29・便30・便35・便60）
struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Meal> { !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var yearImage: Image?
    @State private var weekImage: Image?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("年", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0) + "年").tag($0) }
                    }
                    LabeledContent("食事", value: "\(inYear.count)食")
                    LabeledContent("お店", value: "\(Set(inYear.compactMap { $0.place?.key }).count)軒")
                    LabeledContent("はじめてのお店", value: "\(inYear.filter { $0.place != nil && $0.visitNumber == 1 }.count)軒")
                    LabeledContent("また行きたい", value: "\(Set(inYear.compactMap { $0.place }.filter(\.wantAgain).map(\.key)).count)軒")
                    if let yearImage {
                        ShareLink(item: yearImage, preview: SharePreview("\(year)年のごはん", image: yearImage)) {
                            Label("「\(year)年のごはん」を1枚にして送る", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let weekImage {
                        ShareLink(item: weekImage, preview: SharePreview("今週のごはん", image: weekImage)) {
                            Label("今週のまとめを1枚にして送る", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("\(String(year))年のごはん")
                }
                Section("ジャンル") { counts(inYear.map(\.genre)) }
                Section("よく食べた料理") { counts(inYear.flatMap(\.dishes), limit: 15) }
                Section("よく行った街") { counts(inYear.map(\.area).filter { !$0.isEmpty }, limit: 10) }
                Section("よく行ったお店") { counts(inYear.compactMap { $0.place?.name }, limit: 10) }
                Section("月ごと") {
                    ForEach(MonthGroup.make(inYear)) { month in
                        NavigationLink {
                            MonthSheet(month: month)
                        } label: {
                            LabeledContent(month.title, value: "\(month.meals.count)食")
                        }
                    }
                }
            }
            .navigationTitle("数える・まとめ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
            .task(id: year) {
                yearImage = await ShareCards.summaryImage(title: "\(year)年のごはん", meals: inYear)
                let week = meals.filter { $0.date.timeIntervalSinceNow > -7 * 86_400 }
                if week.isEmpty {
                    weekImage = nil
                } else {
                    weekImage = await ShareCards.summaryImage(title: "今週のごはん", meals: week)
                }
            }
        }
    }

    private var years: [Int] {
        Array(Set(meals.map { Calendar.current.component(.year, from: $0.date) } + [Calendar.current.component(.year, from: Date())])).sorted(by: >)
    }

    private var inYear: [Meal] { meals.filter { Calendar.current.component(.year, from: $0.date) == year } }

    /// 数える（便35）。料理名のゆれはまとめる
    private func counts(_ items: [String], limit: Int = 30) -> some View {
        ForEach(Array(CountRow.make(items).prefix(limit))) { row in
            LabeledContent(row.name, value: "\(row.count)")
        }
    }
}

/// 1か月ぶん（便29）
struct MonthSheet: View {
    let month: MonthGroup
    @State private var image: Image?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(month.meals) { meal in
                    NavigationLink(value: meal) {
                        FillPhoto(id: meal.photoIDs.first ?? "", side: 400).aspectRatio(1, contentMode: .fill)
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle("\(month.title)（\(month.meals.count)食）")
        .toolbar {
            if let image {
                ShareLink(item: image, preview: SharePreview(month.title, image: image)) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task { image = await ShareCards.summaryImage(title: "\(month.title)のごはん", meals: month.meals) }
    }
}

/// カレンダーで見る（便33）
struct CalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Meal> { !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("前の月")
                    Spacer()
                    Text(month.formatted(.dateTime.year().month())).font(.brush(22, relativeTo: .title2)).foregroundStyle(Ink.ai)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("次の月")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(["日", "月", "火", "水", "木", "金", "土"], id: \.self) { Text($0).font(.caption).foregroundStyle(Ink.hai) }
                    ForEach(cells.indices, id: \.self) { i in
                        CalendarCell(day: cells[i], meal: cells[i].flatMap { firstMeal(on: $0) })
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .background(Ink.ground)
            .navigationTitle("カレンダー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
        }
    }

    private func shift(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: n, to: month) { month = d }
    }

    private var cells: [Date?] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let lead = calendar.component(.weekday, from: month) - 1
        var out: [Date?] = Array(repeating: nil, count: lead)
        for day in range {
            out.append(calendar.date(byAdding: .day, value: day - 1, to: month))
        }
        return out
    }

    private func firstMeal(on day: Date) -> Meal? {
        meals.last { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }
}

private struct CalendarCell: View {
    let day: Date?
    let meal: Meal?

    var body: some View {
        if let day {
            ZStack(alignment: .topLeading) {
                if let meal {
                    NavigationLink(value: meal) {
                        FillPhoto(id: meal.photoIDs.first ?? "", side: 200)
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Ink.card).aspectRatio(1, contentMode: .fit)
                }
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.caption2.bold())
                    .foregroundStyle(meal == nil ? Ink.hai : .white)
                    .shadow(radius: meal == nil ? 0 : 2)
                    .padding(4)
            }
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit)
        }
    }
}

/// 「たぶん」をまとめて見る（右に払えば「合ってる」。やらなくても困らない。便49）
struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Meal> { $0.needsCheck && !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var drag: CGSize = .zero
    @State private var picking: Meal?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let meal = meals.first {
                    Text("のこり \(meals.count) 件").font(.footnote).foregroundStyle(Ink.hai)
                    MealCard(meal: meal) {}
                        .allowsHitTesting(false)
                        .offset(x: drag.width)
                        .rotationEffect(.degrees(Double(drag.width) / 25))
                        .gesture(
                            DragGesture()
                                .onChanged { drag = $0.translation }
                                .onEnded { value in
                                    if value.translation.width > 110 { confirm(meal) }
                                    else if value.translation.width < -110 { picking = meal }
                                    withAnimation(.spring) { drag = .zero }
                                }
                        )
                    Text(meal.reason.isEmpty ? "このお店で合っていますか" : meal.reason).font(.footnote).foregroundStyle(Ink.hai)
                    HStack(spacing: 12) {
                        Button("ちがう") { picking = meal }.buttonStyle(InkButtonStyle(filled: false))
                        Button("合ってる") { confirm(meal) }.buttonStyle(InkButtonStyle())
                    }
                    Button("あとで") { skip(meal) }.font(.subheadline).foregroundStyle(Ink.hai).frame(minHeight: 44)
                } else {
                    EmptyArt(title: "「たぶん」はありません", message: "ぜんぶ見終わりました。")
                }
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Ink.ground)
            .navigationTitle("「たぶん」を見る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .sheet(item: $picking) { CandidatePicker(meal: $0) }
        }
    }

    private func confirm(_ meal: Meal) {
        meal.needsCheck = false
        meal.confidence = 1
        try? context.save()
        Metrics.count("confirmed")
        AccuracyLog.hit(meal)
    }

    /// あとで（今回は見ない。次に開いたときに後ろへ回すため、自信だけ少し上げる）
    private func skip(_ meal: Meal) {
        meal.needsCheck = false
        try? context.save()
        UndoCenter.shared.offer("あとで見る印を外しました") {
            meal.needsCheck = true
            try? context.save()
        }
    }
}
