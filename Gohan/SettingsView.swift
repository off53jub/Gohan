import Photos
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Meal> { $0.hidden }, sort: \Meal.date, order: .reverse) private var hidden: [Meal]
    @State private var scanner = Scanner.shared
    @State private var keyText = ""
    @State private var hasKey = ClaudeVision.isReady
    @State private var cap = Spend.cap
    @State private var auto = ScanSettings.auto
    @State private var since = ScanSettings.since
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasKey {
                        LabeledContent("Claude", value: "使っています")
                        Button("鍵を外す", role: .destructive) {
                            KeyStore.claudeKey = nil
                            hasKey = false
                        }
                    } else {
                        SecureField("Claude の API キー（sk-ant-…）", text: $keyText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存") {
                            KeyStore.claudeKey = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
                            keyText = ""
                            hasKey = ClaudeVision.isReady
                        }
                        .disabled(keyText.isEmpty)
                    }
                    LabeledContent("今月使った額", value: String(format: "$%.2f", Spend.thisMonth))
                    Stepper(value: $cap, in: 1...50, step: 1) {
                        LabeledContent("月の上限", value: String(format: "$%.0f", cap))
                    }
                    .onChange(of: cap) { _, new in Spend.cap = new }
                } header: {
                    Text("AI（お店と料理名の精度が上がります）")
                } footer: {
                    Text("鍵はこの iPhone のキーチェーンにだけ置きます。鍵が無い・上限に届いたときは、端末の中だけで決めます（料理名がおおまかになります）。目安は1回の食事で 5〜10 円です（写真の枚数で変わります）。初めに過去の写真をまとめて読むと、上限に届くことがあります。")
                }

                Section {
                    Toggle("アプリを開いたら新しい写真を読む", isOn: $auto)
                        .onChange(of: auto) { _, new in ScanSettings.auto = new }
                    DatePicker("この日からの写真を読む", selection: $since, in: ...Date(), displayedComponents: .date)
                        .onChange(of: since) { _, new in ScanSettings.since = new }
                    Button {
                        Task { await scanner.scan() }
                    } label: {
                        if scanner.isRunning {
                            HStack { ProgressView(); Text(scanner.status) }
                        } else {
                            Text("いま読む")
                        }
                    }
                    .disabled(scanner.isRunning)
                    if let last = scanner.lastRun {
                        LabeledContent("前に読んだ時刻") { Text(last, format: .dateTime.month().day().hour().minute()) }
                    }
                } header: {
                    Text("写真の読み込み")
                } footer: {
                    Text("食べている途中で区切らないよう、撮ってから1時間たった写真を読みます。前の日付に変えると、その日からの写真を読み足します。")
                }

                Section("外した記録（\(hidden.count)）") {
                    ForEach(hidden.prefix(30)) { meal in
                        HStack {
                            PhotoThumb(id: meal.photoIDs.first, side: 40)
                            Text(meal.date, format: .dateTime.month().day().hour().minute()).font(.caption)
                            Spacer()
                            Button("戻す") {
                                meal.hidden = false
                                try? context.save()
                            }
                        }
                    }
                }

                Section {
                    Button("写真の許可を確かめる") {
                        Task { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                    }
                    Button("記録を全部消して読み直す", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("版 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")）")
                }
            }
            .navigationTitle("設定")
            .confirmationDialog("記録を全部消しますか", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("全部消して読み直す", role: .destructive) { reset() }
            } message: {
                Text("お店の「また行きたい」とメモも消えます。写真は消えません。")
            }
        }
    }

    private func reset() {
        try? context.delete(model: Meal.self)
        try? context.delete(model: Place.self)
        try? context.save()
        SeenStore.reset()
        Task { await scanner.scan() }
    }
}
