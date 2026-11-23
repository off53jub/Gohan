import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// ふたり（相手の食事・ふたりで行ったお店・反応。便61〜64）
struct TwoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Meal> { !$0.hidden }, sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var store = PartnerStore.shared
    @State private var fileURL: URL?
    @State private var making = false
    @State private var importing = false
    @State private var message: String?
    @State private var myName = PartnerStore.myName

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("自分の呼び名（相手の画面に出ます）", text: $myName)
                        .onChange(of: myName) { _, new in PartnerStore.myName = new }
                    if let fileURL {
                        ShareLink(item: fileURL) { Label("自分の帖を相手に送る（LINE・AirDrop）", systemImage: "square.and.arrow.up") }
                    } else {
                        Button(making ? "用意しています…" : "自分の帖を送る用意をする") { Task { await make() } }
                            .disabled(making)
                    }
                    Button("相手の帖を開く（ファイルから）") { importing = true }
                } header: {
                    Text("渡し合う")
                } footer: {
                    Text("サーバーは使いません。送ったファイル（.gohan）を相手がごはん帖で開くと、ここに並びます。写真は小さくして入れます。新しくしたいときは、また送り合ってください。")
                }
                if let message { Section { Text(message).font(.footnote).foregroundStyle(Ink.hai) } }

                if let book = store.book {
                    Section("ふたりで行った（\(together.count)）") {
                        ForEach(together) { pair in
                            NavigationLink(value: pair.mine) {
                                HStack(spacing: 10) {
                                    PhotoThumb(id: pair.mine.photoIDs.first, side: 48)
                                    if let data = pair.theirs.thumbnail, let image = UIImage(data: data) {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    VStack(alignment: .leading) {
                                        Text(pair.mine.title).font(.headline).foregroundStyle(Ink.ai).lineLimit(1)
                                        Text(pair.mine.date.formatted(.dateTime.year().month().day())).font(.caption).foregroundStyle(Ink.hai)
                                    }
                                }
                            }
                        }
                    }
                    Section("\(book.name)の食事（\(book.meals.count)）") {
                        ForEach(book.meals.prefix(150)) { m in
                            PartnerRow(meal: m, reactions: store.myReactions[m.id.uuidString] ?? []) { text in
                                store.react(m.id, text)
                                fileURL = nil
                            }
                        }
                    }
                    Section {
                        Button("相手の帖を消す", role: .destructive) { store.clear() }
                    } footer: {
                        Text("受け取った日: \(book.sentAt.formatted(.dateTime.month().day().hour().minute()))")
                    }
                }
            }
            .navigationTitle("ふたり")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .navigationDestination(for: Place.self) { PlaceDetailView(place: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.gohanBook, .data]) { result in
                if case .success(let url) = result {
                    do {
                        let count = try store.receive(url, context: context)
                        message = "\(count) 食を受け取りました"
                    } catch {
                        message = "読めませんでした: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private struct Pair: Identifiable {
        let mine: Meal
        let theirs: PartnerMeal
        var id: UUID { mine.id }
    }

    private var together: [Pair] {
        meals.prefix(500).compactMap { m in store.together(with: m).map { Pair(mine: m, theirs: $0) } }
    }

    private func make() async {
        making = true
        fileURL = await store.makeFile(context: context)
        making = false
    }
}

private struct PartnerRow: View {
    let meal: PartnerMeal
    let reactions: [String]
    let react: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let data = meal.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Ink.photo).frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.title).font(.headline).foregroundStyle(Ink.ai).lineLimit(1)
                Text(meal.dishes.joined(separator: "、")).font(.subheadline).foregroundStyle(Ink.sumi).lineLimit(1)
                Text(meal.date.formatted(.dateTime.month().day().hour().minute())).font(.caption).foregroundStyle(Ink.hai)
            }
            Spacer(minLength: 0)
            // 反応（便63）。次に自分の帖を送るときに、相手に届く
            Menu {
                ForEach(["❤︎", "おいしそう", "行きたい", "また行こう"], id: \.self) { text in
                    Button((reactions.contains(text) ? "✓ " : "") + text) { react(text) }
                }
            } label: {
                Image(systemName: reactions.isEmpty ? "face.smiling" : "face.smiling.inverse")
                    .font(.title3).foregroundStyle(reactions.isEmpty ? Ink.hai : Ink.aka)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("反応する")
        }
    }
}
