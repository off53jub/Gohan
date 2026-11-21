import SwiftData
import SwiftUI

/// 1回の食事
struct MealDetailView: View {
    @Bindable var meal: Meal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var confirmHide = false

    var body: some View {
        List {
            Section {
                PhotoPager(ids: meal.photoIDs)
                    .listRowInsets(EdgeInsets())
            }

            Section("お店") {
                if let place = meal.place {
                    NavigationLink(value: place) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.headline)
                            if !place.address.isEmpty {
                                Text(place.address).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(place.visibleMeals.count)回目の記録").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(get: { place.wantAgain }, set: { place.wantAgain = $0 })) {
                        Label("また行きたい", systemImage: place.wantAgain ? "heart.fill" : "heart")
                    }
                    .tint(.pink)
                } else {
                    Text(meal.title).foregroundStyle(.secondary)
                }
                Button(meal.place == nil ? "お店を選ぶ" : "お店を選び直す") { picking = true }
                if meal.needsCheck {
                    Button("このままで合っています") {
                        meal.needsCheck = false
                        meal.confidence = 1
                    }
                }
            }

            Section("料理") {
                Picker("ジャンル", selection: $meal.genre) {
                    ForEach(Genre.all, id: \.self) { Text("\(Genre.emoji($0)) \($0)").tag($0) }
                }
                TextField("料理（「、」で区切る）", text: dishBinding, axis: .vertical)
                if !meal.summary.isEmpty {
                    Text(meal.summary).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("メモ") {
                TextField("だれと・感想など（書かなくても大丈夫）", text: $meal.note, axis: .vertical)
            }

            Section {
                LabeledContent("日時") { Text(meal.date, format: .dateTime.year().month().day().weekday().hour().minute()) }
                LabeledContent("決め方") { Text(meal.source == "claude" ? "Claude" : "端末だけ") }
                if meal.needsCheck {
                    LabeledContent("自信") { Text("\(Int(meal.confidence * 100))%") }
                }
                ShareLink(item: shareText) { Label("共有", systemImage: "square.and.arrow.up") }
                Button("これは食事じゃない", role: .destructive) { confirmHide = true }
            }
        }
        .navigationTitle(meal.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $picking) {
            CandidatePicker(meal: meal)
        }
        .confirmationDialog("この記録を一覧から外しますか", isPresented: $confirmHide, titleVisibility: .visible) {
            Button("外す", role: .destructive) {
                meal.hidden = true
                try? context.save()
                dismiss()
            }
        } message: {
            Text("設定の「外した記録」から戻せます。写真は消えません。")
        }
    }

    private var dishBinding: Binding<String> {
        Binding(
            get: { meal.dishes.joined(separator: "、") },
            set: { text in
                meal.dishes = text.split(whereSeparator: { "、,，\n".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var shareText: String {
        var parts = [meal.title, meal.dishText]
        if let address = meal.place?.address, !address.isEmpty { parts.append(address) }
        return parts.joined(separator: "\n")
    }
}

/// お店を選び直す（候補から1タップ・名前で探す・お店ではない）
struct CandidatePicker: View {
    @Bindable var meal: Meal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceCandidate] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if !results.isEmpty {
                    Section("探した結果") {
                        ForEach(results) { row($0) }
                    }
                }
                Section("近くのお店") {
                    if meal.candidates.isEmpty {
                        Text("候補がありません。上の欄にお店の名前を入れて探してください。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(meal.candidates) { row($0) }
                }
                Section {
                    Button("お店ではない（家・持ち帰りなど）") {
                        meal.place = nil
                        meal.eatenOut = false
                        finish()
                    }
                }
            }
            .searchable(text: $query, prompt: "お店の名前で探す")
            .onSubmit(of: .search) { Task { await search() } }
            .overlay { if searching { ProgressView() } }
            .navigationTitle("お店を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }

    private func row(_ candidate: PlaceCandidate) -> some View {
        Button {
            choose(candidate)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name).foregroundStyle(.primary)
                    Text("\(Int(candidate.distance.rounded()))m\(candidate.visited ? "・前にも行った" : "")\(candidate.address.isEmpty ? "" : "・" + candidate.address)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if meal.place?.key == candidate.key {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func choose(_ candidate: PlaceCandidate) {
        let old = meal.place
        meal.place = PlaceBook.place(for: candidate, date: meal.date, context: context)
        meal.eatenOut = true
        if meal.genre == "その他", let g = Genre.from(category: candidate.category) { meal.genre = g }
        // 選び直して、だれも行っていないことになったお店は消す
        if let old, old.key != candidate.key, !old.wantAgain, old.meals.filter({ $0.id != meal.id }).isEmpty {
            context.delete(old)
        }
        finish()
    }

    private func finish() {
        meal.needsCheck = false
        meal.confidence = 1
        try? context.save()
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
        results = await PlaceFinder.search(text, latitude: lat, longitude: lon, radius: radius)
    }
}
