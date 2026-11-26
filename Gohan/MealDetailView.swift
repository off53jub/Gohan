import PhotosUI
import SwiftData
import SwiftUI

/// 1回の食事（デ9・デ10・便25・便39・便53・便54・便57・便59・便65）
struct MealDetailView: View {
    @Bindable var meal: Meal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var picking = false
    @State private var editingDishes = false
    @State private var editingPhotos = false
    @State private var splitting = false
    @State private var confirmHide = false
    @State private var shareImage: Image?
    @State private var partner = PartnerStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PhotoPager(ids: meal.photoIDs)
                VStack(alignment: .leading, spacing: 18) {
                    header
                    chips
                    if let place = meal.place {
                        WantBigButton(place: place)
                    }
                    if !meal.reason.isEmpty {
                        Label(meal.reason, systemImage: "checkmark")
                            .font(.footnote).foregroundStyle(Ink.hai)
                            .labelStyle(ReasonLabelStyle())
                    }
                    if !meal.summary.isEmpty {
                        Text(meal.summary).font(.callout).foregroundStyle(Ink.sumi)
                    }
                    memo
                    if let together = partner.together(with: meal) {
                        TogetherRow(partner: together, name: partner.book?.name ?? "ふたり")
                    }
                    if !meal.reactions.isEmpty {
                        Text("相手から: \(meal.reactions.joined(separator: " "))").font(.footnote).foregroundStyle(Ink.aka)
                    }
                    previousVisits
                    clues
                    Toggle(isOn: $meal.special) { Text("記念日のごはん").font(.subheadline) }
                        .tint(Ink.aka)
                    actions
                }
                .padding(20)
            }
        }
        .background(Ink.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview(meal.title, image: shareImage)) {
                        Image(systemName: "square.and.arrow.up").accessibilityLabel("送る")
                    }
                }
            }
        }
        .task(id: meal.photoIDs.first) { shareImage = await ShareCards.mealImage(meal) }
        .sheet(isPresented: $picking) { CandidatePicker(meal: meal) }
        .sheet(isPresented: $editingDishes) { DishEditor(meal: meal) }
        .sheet(isPresented: $editingPhotos) { PhotoEditor(meal: meal) }
        .sheet(isPresented: $splitting) { SplitView(meal: meal) }
        .confirmationDialog("この記録を一覧から外しますか", isPresented: $confirmHide, titleVisibility: .visible) {
            Button("外す", role: .destructive) {
                MealActions.hide(meal, context: context)
                dismiss()
            }
        } message: {
            Text("設定の「外した記録」から戻せます。写真は消えません。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let place = meal.place {
                    NavigationLink(value: place) {
                        HStack(spacing: 4) {
                            Text(meal.title).font(.brush(26, relativeTo: .title)).foregroundStyle(Ink.ai)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(Ink.hai)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(meal.title).font(.brush(26, relativeTo: .title)).foregroundStyle(Ink.ai)
                }
                Text(subtitle).font(.footnote).foregroundStyle(Ink.hai)
            }
            Spacer()
            if meal.visitNumber >= 1, meal.place != nil {
                Stamp(text: "\(meal.visitNumber)回目", size: 60)
            }
        }
    }

    private var subtitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E) H:mm"
        var parts = [meal.area, f.string(from: meal.date)].filter { !$0.isEmpty }
        if meal.needsCheck { parts.append("たぶん") }
        return parts.joined(separator: "・")
    }

    /// 札をたたくと直せる（便57）
    private var chips: some View {
        FlowRow(spacing: 8) {
            Menu {
                ForEach(Genre.all, id: \.self) { g in
                    Button(g) {
                        let old = meal.genre
                        guard old != g else { return }
                        meal.genre = g
                        meal.genreByHand = true
                        Metrics.count("genreEdits")
                        // 直したジャンルを覚える（写真の判定の名前 → ジャンル）と、外れ方の記録
                        GenreLearn.record(label: meal.visionLabel, genre: g)
                        AccuracyLog.genreFixed(meal, from: old, to: g)
                    }
                }
            } label: {
                Chip(text: meal.genre, strong: true)
            }
            ForEach(meal.dishes, id: \.self) { dish in
                Button { editingDishes = true } label: { Chip(text: dish) }
                    .buttonStyle(.plain)
            }
            Button { editingDishes = true } label: { Chip(text: meal.dishes.isEmpty ? "＋ 料理" : "＋") }
                .buttonStyle(.plain)
                .accessibilityLabel("料理を直す")
            if let kind = meal.kindLabel { Chip(text: kind) }
        }
    }

    private var memo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ひとこと").sectionLabel()
            TextField("書かなくても大丈夫です", text: $meal.note, axis: .vertical)
                .font(.body)
                .padding(12)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
        }
    }

    @ViewBuilder
    private var previousVisits: some View {
        let others = meal.place?.visibleMeals.filter { $0.id != meal.id } ?? []
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("ほかに来た日").sectionLabel()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(others.prefix(10)) { other in
                            NavigationLink(value: other) {
                                HStack(spacing: 10) {
                                    PhotoThumb(id: other.photoIDs.first, side: 44, corner: 10)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(other.date.formatted(.dateTime.month().day())).font(.footnote.bold()).foregroundStyle(Ink.ai)
                                        Text(other.dishText).font(.caption).foregroundStyle(Ink.hai).lineLimit(1)
                                    }
                                }
                                .padding(8)
                                .padding(.trailing, 6)
                                .card(radius: 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// 看板・メニュー・レシートの写真（便25）
    @ViewBuilder
    private var clues: some View {
        if !meal.cluePhotoIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("手がかりにした写真").sectionLabel()
                HStack(spacing: 8) {
                    ForEach(meal.cluePhotoIDs, id: \.self) { PhotoThumb(id: $0, side: 72) }
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            linkButton("お店がちがうとき") { picking = true }
            linkButton("写真の順番・外す・足す") { editingPhotos = true }
            if meal.photoIDs.count >= 2 { linkButton("食事を分ける") { splitting = true } }
            if previousMeal != nil { linkButton("前の食事とくっつける") { mergeWithPrevious() } }
            // 写真アプリの特定の写真は開けないので、写真アプリを開く（日時で探せる。便39）
            linkButton("写真アプリを開く") { if let url = URL(string: "photos-redirect://") { openURL(url) } }
            linkButton("これは食事じゃない", role: .destructive) { confirmHide = true }
            if MakerMode.on {
                Text("決め方: \(sourceText)").font(.caption).foregroundStyle(Ink.hai).padding(.top, 6)
            }
        }
    }

    private func linkButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).font(.subheadline).underline()
                .foregroundStyle(role == .destructive ? Ink.aka : Ink.hai)
                .frame(minHeight: 40, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var sourceText: String {
        switch meal.source {
        case "claude": "AI"
        case "claude-light": "AI（軽いモデル）"
        case "batch": meal.aiPending ? "AI の順番待ち（いまは端末の判断）" : "AI（まとめ処理）"
        case "known": "前に来たお店"
        case "backup": "バックアップから"
        default: meal.aiPending ? "端末だけ（つながったら AI に聞き直します）" : "端末だけ"
        }
    }

    /// 3 時間以内の、ひとつ前の食事
    private var previousMeal: Meal? {
        let start = meal.date.addingTimeInterval(-3 * 3600)
        let end = meal.date
        let id = meal.id
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.date >= start && $0.date < end && !$0.hidden && $0.id != id },
                                               sortBy: [SortDescriptor(\.date, order: .reverse)])
        return try? context.fetch(descriptor).first
    }

    /// 前の食事とくっつける（便53）
    private func mergeWithPrevious() {
        guard let previous = previousMeal else { return }
        let oldPhotos = previous.photoIDs
        let oldEnd = previous.endDate
        previous.photoIDs += meal.photoIDs.filter { !previous.photoIDs.contains($0) }
        previous.endDate = max(previous.endDate, meal.endDate)
        meal.hidden = true
        try? context.save()
        Metrics.count("merges")
        let current = meal
        UndoCenter.shared.offer("前の食事とくっつけました") {
            previous.photoIDs = oldPhotos
            previous.endDate = oldEnd
            current.hidden = false
            try? context.save()
        }
        dismiss()
    }
}

private struct ReasonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 6) {
            configuration.icon.foregroundStyle(Ink.ai)
            configuration.title
        }
    }
}

/// 大きな「また行きたい」
struct WantBigButton: View {
    @Bindable var place: Place
    @Environment(\.modelContext) private var context
    @State private var bump = false

    var body: some View {
        Button {
            place.wantAgain.toggle()
            try? context.save()
            bump.toggle()
        } label: {
            Label("また行きたい", systemImage: place.wantAgain ? "heart.fill" : "heart")
                .font(.system(.body, weight: .bold))
                .foregroundStyle(place.wantAgain ? Ink.aka : Ink.hai)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(place.wantAgain ? Ink.aka : Ink.line, lineWidth: 2))
                .symbolEffect(.bounce, value: bump)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: bump)
        .accessibilityValue(place.wantAgain ? "オン" : "オフ")
    }
}

/// 相手も同じ時間・同じ場所で食べていた（便62）
struct TogetherRow: View {
    let partner: PartnerMeal
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            if let data = partner.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ふたりで").font(.caption.bold()).foregroundStyle(Ink.aka)
                Text("\(name)の写真: \(partner.dishes.joined(separator: "、"))").font(.footnote).foregroundStyle(Ink.sumi).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }
}

/// 札を横に並べ、はみ出したら折り返す
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 料理を札ごとに直す（便57）
struct DishEditor: View {
    @Bindable var meal: Meal
    @Environment(\.dismiss) private var dismiss
    @State private var dishes: [String] = []
    @State private var newDish = ""

    var body: some View {
        NavigationStack {
            List {
                Section("料理") {
                    ForEach(dishes.indices, id: \.self) { i in
                        TextField("料理", text: $dishes[i])
                    }
                    .onDelete { dishes.remove(atOffsets: $0) }
                    HStack {
                        TextField("料理を足す", text: $newDish)
                            .onSubmit(add)
                        Button("足す", action: add).disabled(newDish.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("料理を直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決める") {
                        add()
                        let old = meal.dishes
                        meal.dishes = dishes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if old != meal.dishes { Metrics.count("dishEdits") }
                        dismiss()
                    }
                }
            }
            .onAppear { dishes = meal.dishes }
        }
    }

    private func add() {
        let text = newDish.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        dishes.append(text)
        newDish = ""
    }
}

/// 写真を外す・足す（便54）
struct PhotoEditor: View {
    @Bindable var meal: Meal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(meal.photoIDs, id: \.self) { id in
                        HStack {
                            PhotoThumb(id: id, side: 64)
                            if id == meal.photoIDs.first {
                                Text("表紙").font(.caption).foregroundStyle(Ink.ai)
                            }
                            Spacer()
                            if id != meal.photoIDs.first {
                                Button("表紙にする") { makeCover(id) }
                                    .buttonStyle(.borderless)
                            }
                            Button("外す", role: .destructive) { remove(id) }
                                .buttonStyle(.borderless)
                                .disabled(meal.photoIDs.count <= 1)
                        }
                    }
                    .onMove { from, to in
                        meal.photoIDs.move(fromOffsets: from, toOffset: to)
                        try? context.save()
                    }
                } footer: {
                    Text("右の三本線をつかんで動かすと、順番を変えられます。いちばん上の写真が表紙（一覧に出る写真）になります。外した写真は写真アプリには残ります。")
                }
                Section {
                    PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                        Label("写真を足す", systemImage: "plus")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))   // 並べ替えのつまみを常に出す
            .navigationTitle("写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onChange(of: picked) { _, items in
                let ids = items.compactMap(\.itemIdentifier).filter { !meal.photoIDs.contains($0) }
                meal.photoIDs += ids
                picked = []
                try? context.save()
            }
        }
    }

    private func makeCover(_ id: String) {
        meal.photoIDs.removeAll { $0 == id }
        meal.photoIDs.insert(id, at: 0)
        try? context.save()
    }

    private func remove(_ id: String) {
        let old = meal.photoIDs
        meal.photoIDs.removeAll { $0 == id }
        try? context.save()
        UndoCenter.shared.offer("写真を外しました") {
            meal.photoIDs = old
            try? context.save()
        }
    }
}

/// 食事を分ける（便53）: 選んだ写真を、別の食事にする
struct SplitView: View {
    @Bindable var meal: Meal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(meal.photoIDs, id: \.self) { id in
                        Button {
                            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                        } label: {
                            HStack {
                                PhotoThumb(id: id, side: 64)
                                Spacer()
                                Image(systemName: chosen.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(id) ? Ink.ai : Ink.hai)
                                    .font(.title3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("選んだ写真を、別の食事にします。お店はあとで選べます。")
                }
            }
            .navigationTitle("食事を分ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("分ける") { split() }.disabled(chosen.isEmpty || chosen.count == meal.photoIDs.count)
                }
            }
        }
    }

    private func split() {
        let moved = meal.photoIDs.filter { chosen.contains($0) }
        let oldPhotos = meal.photoIDs
        let assets = moved.compactMap { PhotoLoader.asset($0) }
        let dates = assets.compactMap(\.creationDate).sorted()
        let fresh = Meal(date: dates.first ?? meal.date, endDate: dates.last ?? meal.endDate, photoIDs: moved,
                         latitude: assets.first?.location?.coordinate.latitude ?? meal.latitude,
                         longitude: assets.first?.location?.coordinate.longitude ?? meal.longitude)
        fresh.area = meal.area
        fresh.region = meal.region
        fresh.genre = meal.genre
        fresh.candidates = meal.candidates
        fresh.needsCheck = true
        context.insert(fresh)
        meal.photoIDs.removeAll { chosen.contains($0) }
        try? context.save()
        Metrics.count("splits")
        let current = meal
        UndoCenter.shared.offer("食事を分けました") {
            current.photoIDs = oldPhotos
            context.delete(fresh)
            try? context.save()
        }
        dismiss()
    }
}

/// お店を選び直す（上の 3 つは大きく・名前で探す・お店ではない。便50・便51・便52）
struct CandidatePicker: View {
    @Bindable var meal: Meal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceCandidate] = []
    @State private var searching = false
    @State private var refreshing = false
    @State private var googleDone = false
    @State private var others: [Meal] = []
    @State private var chosen: PlaceCandidate?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !results.isEmpty {
                        Text("探した結果").sectionLabel()
                        ForEach(results) { row($0) }
                    }
                    let top = Array(meal.candidates.prefix(3))
                    if !top.isEmpty {
                        Text("このあたりのお店").sectionLabel()
                        ForEach(top) { big($0) }
                    }
                    let rest = Array(meal.candidates.dropFirst(3))
                    if !rest.isEmpty {
                        DisclosureGroup("ほかの候補（\(rest.count)）") {
                            VStack(spacing: 8) { ForEach(rest) { row($0) } }
                        }
                        .font(.subheadline).tint(Ink.ai)
                    }
                    if refreshing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("近くのお店を探しています").font(.callout).foregroundStyle(Ink.hai)
                        }
                    } else if meal.candidates.isEmpty && results.isEmpty {
                        Text(meal.latitude == nil
                             ? "この食事の写真には場所の記録がないので、近くのお店を出せません。上の欄にお店の名前を入れて探してください。"
                             : "候補がありません。上の欄にお店の名前を入れて探してください。")
                            .font(.callout).foregroundStyle(Ink.hai)
                    }
                    if meal.latitude != nil, KeyStore.googleKey != nil, !googleDone, !refreshing {
                        Button("見つからないときは Google でも探す") { Task { await refreshNearby(google: true) } }
                            .buttonStyle(InkButtonStyle(filled: false))
                    }
                    Button("お店ではない（家・持ち帰りなど）") { notShop() }
                        .buttonStyle(InkButtonStyle(filled: false))
                    if (meal.candidates + results).contains(where: { $0.category.hasPrefix("genre:") }) {
                        HotPepperCredit()
                    }
                    if (meal.candidates + results).contains(where: { $0.category.hasPrefix("yahoo:") }) {
                        YahooCredit()
                    }
                    if (meal.candidates + results).contains(where: { $0.category.hasPrefix("osm:") }) {
                        OSMCredit()
                    }
                }
                .padding(20)
            }
            .background(Ink.ground)
            .searchable(text: $query, prompt: "お店の名前で探す")
            .onSubmit(of: .search) { Task { await search() } }
            .overlay { if searching { ProgressView() } }
            .task { await refreshNearby() }
            .navigationTitle("お店を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .confirmationDialog(batchTitle, isPresented: Binding(get: { !others.isEmpty }, set: { if !$0 { others = []; dismiss() } }),
                                titleVisibility: .visible) {
                Button("ほかの \(others.count) 件も直す") { fixOthers() }
                Button("この食事だけ", role: .cancel) { others = []; dismiss() }
            }
        }
    }

    private var batchTitle: String {
        "同じ所で「\(meal.place == nil ? "" : (others.first?.place?.name ?? ""))」になっている食事が、ほかに \(others.count) 件あります"
    }

    private func big(_ c: PlaceCandidate) -> some View {
        Button { choose(c) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.name).font(.brush(19, relativeTo: .headline)).foregroundStyle(Ink.ai)
                    Text(detail(c)).font(.caption).foregroundStyle(Ink.hai).lineLimit(1)
                }
                Spacer()
                if meal.place?.key == c.key { Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.ai).font(.title3) }
            }
            .padding(16)
            .frame(minHeight: 64)
            .card(radius: 16)
        }
        .buttonStyle(.plain)
    }

    private func row(_ c: PlaceCandidate) -> some View {
        Button { choose(c) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).foregroundStyle(Ink.sumi)
                    Text(detail(c)).font(.caption).foregroundStyle(Ink.hai).lineLimit(1)
                }
                Spacer()
                if meal.place?.key == c.key { Image(systemName: "checkmark").foregroundStyle(Ink.ai) }
            }
            .padding(12)
            .card(radius: 12)
        }
        .buttonStyle(.plain)
    }

    private func detail(_ c: PlaceCandidate) -> String {
        var parts = ["\(Int(c.distance.rounded()))m"]
        if c.visited { parts.append("前にも行った") }
        if !c.address.isEmpty { parts.append(c.address) }
        return parts.joined(separator: "・")
    }

    private func choose(_ candidate: PlaceCandidate) {
        let old = meal.place
        let oldState = (meal.needsCheck, meal.confidence, meal.eatenOut)
        // 直したら覚える（便51）
        Corrections.learn(latitude: meal.latitude, longitude: meal.longitude, wrong: old?.name, right: candidate.name)
        if old?.key != candidate.key { AccuracyLog.placeFixed(meal, to: candidate, oldName: old?.name) }
        let place = PlaceBook.place(for: candidate, date: meal.date, context: context)
        meal.place = place
        meal.eatenOut = true
        meal.spot = ""
        meal.reason = "自分で選びました"
        if meal.genre == "その他", let g = Genre.from(category: candidate.category) { meal.genre = g }
        meal.needsCheck = false
        meal.confidence = 1
        try? context.save()
        let current = meal
        UndoCenter.shared.offer("お店を「\(place.name)」にしました") {
            current.place = old
            (current.needsCheck, current.confidence, current.eatenOut) = oldState
            try? context.save()
        }
        // 同じ間違いをまとめて直す（便52）
        if let old, old.key != place.key {
            others = old.visibleMeals.filter { other in
                guard other.id != meal.id, let a = other.latitude, let b = other.longitude, let c = meal.latitude, let d = meal.longitude else { return false }
                return Matcher.distance(a, b, c, d) <= 100
            }
            chosen = candidate
            if others.isEmpty { cleanUp(old); dismiss() }
        } else {
            dismiss()
        }
    }

    private func fixOthers() {
        guard let chosen else { return }
        let place = PlaceBook.place(for: chosen, date: meal.date, context: context)
        let old = others.first?.place
        for other in others {
            other.place = place
            other.needsCheck = false
            other.confidence = 1
            other.reason = "まとめて直しました"
        }
        if let old { cleanUp(old) }
        try? context.save()
        Metrics.count("batchFixes")
        others = []
        dismiss()
    }

    /// だれも行っていないことになったお店は消す（また行きたい・行ってみたい のお店は残す）
    private func cleanUp(_ place: Place) {
        if !place.wantAgain, !place.wantToTry, place.visibleMeals.isEmpty, place.meals.allSatisfy({ $0.hidden }) {
            context.delete(place)
            try? context.save()
        }
    }

    private func notShop() {
        let old = meal.place
        Corrections.learn(latitude: meal.latitude, longitude: meal.longitude, wrong: old?.name, right: nil)
        AccuracyLog.notShop(meal)
        meal.place = nil
        meal.eatenOut = false
        meal.needsCheck = false
        meal.confidence = 1
        meal.reason = ""
        if let old { cleanUp(old) }
        try? context.save()
        let current = meal
        UndoCenter.shared.offer("お店ではない、にしました") {
            current.place = old
            current.eatenOut = true
            try? context.save()
        }
        dismiss()
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        // 写真の位置が無ければ、東京の真ん中から広く探す
        let lat = meal.latitude ?? 35.681, lon = meal.longitude ?? 139.767
        let radius = meal.latitude == nil ? 50_000.0 : 3_000.0
        // Google は Apple・ホットペッパーで見つからないときだけ（使いすぎると料金がかかる。本人「必要に応じて」2026-11-25）
        results = await PlaceFinder.searchWithFallback(text, latitude: lat, longitude: lon, radius: radius)
    }

    /// 開いたとき、候補が少なければ近くのお店を探し直す（PC から入れた食事・地図の検索が混んで空だった食事のため）。
    /// ふだんは Apple・ホットペッパーだけ。Google は「Google でも探す」を押したときだけ
    private func refreshNearby(google useGoogle: Bool = false) async {
        guard let lat = meal.latitude, let lon = meal.longitude, useGoogle || meal.candidates.count < 5 else { return }
        refreshing = true
        defer { refreshing = false }
        let found = useGoogle
            ? await GooglePlaces.nearby(latitude: lat, longitude: lon, radius: 300)
            : await PlaceFinder.nearbyAll(latitude: lat, longitude: lon, radius: 300)
        if useGoogle { googleDone = true }
        let merged = PlaceFinder.merge([meal.candidates, found])
        guard merged.count > meal.candidates.count else { return }
        let ranked = Matcher.applyGenre(Matcher.rank(merged, lines: [], dishLabel: meal.visionLabel), photoGenre: meal.genre)
        meal.candidates = Array(ranked.prefix(20))
        try? context.save()
    }
}
