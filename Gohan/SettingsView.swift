import CoreImage.CIFilterBuiltins
import MapKit
import Photos
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 設定（ふだん / くわしい。デ22）
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Meal> { $0.hidden }, sort: \Meal.date, order: .reverse) private var hidden: [Meal]
    @State private var scanner = Scanner.shared
    @State private var auto = ScanSettings.auto
    @State private var since = ScanSettings.since
    @State private var showSmall = ScanSettings.showSmall
    @State private var calendar = CalendarClue.enabled
    @State private var near = LocationWatch.nearAlerts
    @State private var lock = FaceLock.enabled
    @State private var receiving = false
    @State private var exportURL: URL?
    @State private var pdfURL: URL?
    @State private var backupURL: URL?
    @State private var restoring = false
    @State private var restoreMessage: String?
    @State private var limited = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    @State private var locationRatio: Double?
    @State private var maker = MakerMode.on
    @State private var versionTaps = 0

    var body: some View {
        NavigationStack {
            Form {
                aiSection
                photoSection
                Section {
                    NavigationLink("おうち・職場の場所") { SpotsView() }
                    Toggle("飲み物だけ・おやつも並べる", isOn: $showSmall)
                        .onChange(of: showSmall) { _, new in ScanSettings.showSmall = new }
                    Toggle("予定表を手がかりにする", isOn: $calendar)
                        .onChange(of: calendar) { _, new in
                            CalendarClue.enabled = new
                            if new { Task { calendar = await CalendarClue.request(); CalendarClue.enabled = calendar } }
                        }
                    Toggle("また行きたいお店の近くに来たら教える", isOn: $near)
                        .onChange(of: near) { _, new in
                            LocationWatch.nearAlerts = new
                            if new { LocationWatch.shared.askAlways() }
                            Task { await scanner.refreshFences(context: context) }
                        }
                    NavigationLink("記念日") { AnniversariesView() }
                } header: {
                    Text("ふだん")
                } footer: {
                    Text("おうち・職場で食べたものは、お店を探さずに「おうちごはん」「職場で」にします。近くに来たら教えるには、位置情報を「常に」にする必要があります。")
                }
                Section {
                    Toggle("Face ID で開く", isOn: $lock).onChange(of: lock) { _, new in FaceLock.enabled = new }
                    NavigationLink("何を送っているか") { PrivacyView() }
                } header: {
                    Text("安心")
                }
                backupSection
                hiddenSection
                Section {
                    if maker {
                        NavigationLink("くわしい設定（作る人のメニュー）") { AdvancedSettingsView() }
                        Button("作る人のメニューを隠す") {
                            MakerMode.on = false
                            maker = false
                        }
                    }
                } footer: {
                    // 「版」を 5 回たたくと、作る人のメニューが出る
                    Text("版 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")）")
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 5 {
                                MakerMode.on = true
                                maker = true
                                versionTaps = 0
                            }
                        }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .sheet(isPresented: $receiving) { KeyReceiveView() }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    do {
                        let n = try Backup.restore(from: url, context: context)
                        restoreMessage = "\(n) 食を戻しました"
                    } catch {
                        restoreMessage = "読めませんでした: \(error.localizedDescription)"
                    }
                }
            }
            .task { locationRatio = LocationCheck.ratio() }
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        // 鍵がもう入っていれば、ふだんは出さない（作る人のメニューでは出す）
        if maker || !ClaudeLink.isReady {
            aiSectionBody
        }
    }

    private var aiSectionBody: some View {
        Section {
            LabeledContent("AI", value: aiState)
            Button("AI の鍵を受け取る（QR）") { receiving = true }
            if maker, AISettings.showCost {
                LabeledContent("今月使った額", value: String(format: "$%.2f / $%.0f", Spend.thisMonth, Spend.cap))
            }
        } header: {
            Text("AI（お店と料理名が正確になります）")
        } footer: {
            Text("鍵をもらう人は、渡す人の iPhone で「くわしい設定 → 鍵を渡す」の QR を読み、6 桁の数字を入れます。")
        }
    }

    private var aiState: String {
        if AISettings.deviceOnly { return "使わない（端末だけ）" }
        if !ClaudeLink.isReady { return "まだ鍵がありません" }
        if !Spend.canSpend { return "今月はお休み中" }
        return ClaudeLink.usesRelay ? "使っています（中継）" : "使っています"
    }

    private var photoSection: some View {
        Section {
            Toggle("アプリを開いたら新しい写真を読む", isOn: $auto)
                .onChange(of: auto) { _, new in ScanSettings.auto = new }
            DatePicker("この日からの写真を読む", selection: $since, in: ...Date(), displayedComponents: .date)
                .onChange(of: since) { _, new in ScanSettings.since = new }
            Button {
                Task { await scanner.scan(mode: .backfill) }
            } label: {
                if scanner.isRunning {
                    HStack { ProgressView(); Text(scanner.status) }
                } else {
                    Text("いま全部読む")
                }
            }
            .disabled(scanner.isRunning)
            if let last = scanner.lastRun {
                LabeledContent("前に読んだ時刻") { Text(last, format: .dateTime.month().day().hour().minute()) }
            }
            if limited {
                VStack(alignment: .leading, spacing: 6) {
                    Text("写真は「選んだ写真だけ」見られる設定です。ごはんの写真を自動で見つけるには「フルアクセス」にしてください。")
                        .font(.footnote)
                    Button("選ぶ写真を足す") { presentLimitedPicker() }
                    Button("設定アプリを開く") { openSettings() }
                }
            }
            if let ratio = locationRatio, ratio < 0.5 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近の写真の \(Int((1 - ratio) * 100))% に場所が入っていません。場所が無いと、お店が分かりません。")
                        .font(.footnote).foregroundStyle(Ink.aka)
                    Text("設定アプリ → プライバシーとセキュリティ → 位置情報サービス → カメラ →「このAppの使用中」にして、「正確な位置情報」をオンにしてください。")
                        .font(.footnote)
                    Button("設定アプリを開く") { openSettings() }
                }
            }
        } header: {
            Text("写真の読み込み")
        } footer: {
            Text("食べている途中で区切らないよう、撮ってから1時間たった写真を読みます。")
        }
    }

    private var backupSection: some View {
        Section {
            if let backupURL {
                ShareLink(item: backupURL) { Label("バックアップを保存する", systemImage: "externaldrive") }
            } else {
                Button("バックアップを作る") { backupURL = Backup.write(context: context) }
            }
            Button("バックアップから戻す") { restoring = true }
            if let exportURL {
                ShareLink(item: exportURL) { Label("表（CSV）を送る", systemImage: "tablecells") }
            } else {
                Button("表（CSV）に書き出す") { exportURL = Backup.csv(allMeals) }
            }
            if let pdfURL {
                ShareLink(item: pdfURL) { Label("写真つき PDF を送る", systemImage: "doc.richtext") }
            } else {
                Button("今年の写真つき PDF を作る") {
                    Task { pdfURL = await Backup.pdf(allMeals.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .year) }, title: "ごはん帖 \(Calendar.current.component(.year, from: Date()))") }
                }
            }
            if let restoreMessage { Text(restoreMessage).font(.footnote).foregroundStyle(Ink.hai) }
        } header: {
            Text("消えないように")
        } footer: {
            Text("記録は iPhone のバックアップ（iCloud）にも入ります。週に1回、「ファイル」アプリの「このiPhone内 → ごはん帖」にも自動で写しを置きます\(Backup.lastWritten.map { "（前回 \($0.formatted(.dateTime.month().day()))）" } ?? "")。機種変更のあとは、写真を iCloud の印から見つけ直します。")
        }
    }

    private var allMeals: [Meal] {
        (try? context.fetch(FetchDescriptor<Meal>(predicate: #Predicate { !$0.hidden }))) ?? []
    }

    private var hiddenSection: some View {
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
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

/// くわしい設定（鍵・中継・費用・モデル・送り方・作る側の物差し）
struct AdvancedSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var keyText = ""
    @State private var hasKey = KeyStore.claudeKey != nil
    @State private var relayURL = AISettings.relayURL
    @State private var relayToken = ""
    @State private var cap = Spend.cap
    @State private var showCost = AISettings.showCost
    @State private var deviceOnly = AISettings.deviceOnly
    @State private var hideFaces = AISettings.hideFaces
    @State private var batchOld = AISettings.batchOld
    @State private var light = AISettings.lightForEasy
    @State private var backfillCharging = ScanSettings.backfillOnlyCharging
    @State private var videos = ScanSettings.videos
    @State private var companions = ScanSettings.companions
    @State private var imageSearch = AISettings.imageSearch
    @State private var escalate = AISettings.escalate
    @State private var confirmReset = false
    @State private var giving = false
    @State private var webCheck = AISettings.webCheck
    @State private var googleKey = ""
    @State private var hotpepperKey = ""
    @State private var hasGoogle = KeyStore.googleKey != nil
    @State private var hasHotpepper = KeyStore.hotpepperKey != nil
    @State private var logURL: URL?

    /// 「お店の候補を増やす」の下の説明と、今月の回数・最後の失敗
    private var shopSourcesFooter: String {
        var lines = ["Apple のマップに載っていないお店も候補に入ります。鍵は自分で取って、この iPhone にだけ置きます。写真の位置（だいたいの場所）がそれぞれの会社に送られます。"]
        let calls = "今月の呼び出し: Google \(Metrics.value("googleCalls")) 回（失敗 \(Metrics.value("googleErrors")) 回）"
        let others = "ホットペッパー \(Metrics.value("hotpepperCalls")) 回・ネットで確かめた \(Metrics.value("webChecks")) 回"
        lines.append(calls + "・" + others)
        let search = "画像検索 \(Metrics.value("imageSearches"))/\(ImageSearch.monthlyCap) 回"
        let shops = "お店の写真を探した \(Metrics.value("lookupShops"))/\(LookAlike.monthlyShopLookups) 軒"
        let photos = "取った写真 \(Metrics.value("googlePhotos"))/\(LookAlike.monthlyPhotoFetches) 枚・見比べた \(Metrics.value("lookAlikes")) 回"
        lines.append("迷ったとき: " + search + "・" + shops + "・" + photos)
        lines.append("強いモデルで聞き直した \(Metrics.value("escalations")) 回・ふたり帖の答えで補った \(Metrics.value("partnerFixes")) 回")
        let more = "OpenStreetMap \(Metrics.value("osmCalls"))/\(OSMPlaces.monthlyCap) 回"
        let paid = "Foursquare \(Metrics.value("foursquareCalls"))/\(FoursquarePlaces.monthlyCap) 回・クチコミ \(Metrics.value("reviewChecks"))/\(ReviewMatch.monthlyCap) 軒"
        lines.append(more + "・" + paid)
        if let p = GooglePlaces.lastProblem { lines.append("Google の最後の失敗: " + p) }
        if let p = ImageSearch.lastProblem { lines.append("画像検索の最後の失敗: " + p) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Form {
            Section {
                if hasKey {
                    LabeledContent("Claude の鍵", value: "入っています")
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
                        hasKey = KeyStore.claudeKey != nil
                    }
                    .disabled(keyText.isEmpty)
                }
                Button("鍵を渡す（QR を出す）") { giving = true }
                    .disabled(!ClaudeLink.isReady)
            } header: {
                Text("鍵")
            } footer: {
                Text("鍵はこの iPhone のキーチェーンにだけ置きます。QR には 6 桁の数字で鍵をかけます。")
            }
            Section {
                TextField("中継サーバーの URL（https://…）", text: $relayURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("合言葉", text: $relayToken)
                Button("中継を使う") {
                    AISettings.relayURL = relayURL
                    if !relayToken.isEmpty { KeyStore.relayToken = relayToken }
                    relayToken = ""
                }
                if ClaudeLink.usesRelay {
                    Button("中継をやめる", role: .destructive) {
                        AISettings.relayURL = ""
                        KeyStore.relayToken = nil
                        relayURL = ""
                    }
                }
            } header: {
                Text("中継サーバー")
            } footer: {
                Text("鍵を端末に置かず、自分で立てた中継サーバー（relay フォルダ）を通します。費用も中継側で数えます。")
            }
            Section {
                Toggle("この端末で費用を見せる", isOn: $showCost).onChange(of: showCost) { _, new in AISettings.showCost = new }
                LabeledContent("今月使った額", value: String(format: "$%.2f", Spend.thisMonth))
                Stepper(value: $cap, in: 1...50, step: 1) {
                    LabeledContent("月の上限", value: String(format: "$%.0f", cap))
                }
                .onChange(of: cap) { _, new in Spend.cap = new }
            } header: {
                Text("費用")
            } footer: {
                Text("目安は1回の食事で 5〜10 円です。上限に届くと、その月は端末だけで判定します。")
            }
            Section {
                Toggle("端末だけで判定する（写真を送らない）", isOn: $deviceOnly).onChange(of: deviceOnly) { _, new in AISettings.deviceOnly = new }
                Toggle("人の顔を隠してから送る", isOn: $hideFaces).onChange(of: hideFaces) { _, new in AISettings.hideFaces = new }
                Toggle("かんたんな写真は軽いモデルで", isOn: $light).onChange(of: light) { _, new in AISettings.lightForEasy = new }
                Toggle("古い写真はまとめて安く（半額・数時間かかる）", isOn: $batchOld).onChange(of: batchOld) { _, new in AISettings.batchOld = new }
                Toggle("古い写真は充電中・Wi-Fi のときに読む", isOn: $backfillCharging)
                    .onChange(of: backfillCharging) { _, new in ScanSettings.backfillOnlyCharging = new }
                Toggle("動画からも1コマ拾う", isOn: $videos).onChange(of: videos) { _, new in ScanSettings.videos = new }
                Toggle("食事中に撮ったほかの写真（人・お店の中）も入れる", isOn: $companions)
                    .onChange(of: companions) { _, new in ScanSettings.companions = new }
                Toggle("迷ったときだけ、AI にネットで確かめてもらう", isOn: $webCheck).onChange(of: webCheck) { _, new in AISettings.webCheck = new }
                Toggle("迷ったときだけ、いちばん強いモデル（Opus）に聞き直す", isOn: $escalate)
                    .onChange(of: escalate) { _, new in AISettings.escalate = new }
                Toggle("迷ったときだけ、料理の写真で画像検索（Google・月 \(ImageSearch.monthlyCap) 回まで）", isOn: $imageSearch)
                    .onChange(of: imageSearch) { _, new in AISettings.imageSearch = new }
            } header: {
                Text("送り方・読み方")
            } footer: {
                Text("ネットで確かめるのは、お店の自信が低いときだけです（1 回 数円）。")
            }
            Section {
                if hasGoogle {
                    LabeledContent("Google", value: "使っています")
                    Button("Google の鍵を外す", role: .destructive) { KeyStore.googleKey = nil; hasGoogle = false }
                } else {
                    SecureField("Google Places API の鍵", text: $googleKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存") {
                        KeyStore.googleKey = googleKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        googleKey = ""
                        hasGoogle = KeyStore.googleKey != nil
                    }
                    .disabled(googleKey.isEmpty)
                }
                LabeledContent("Foursquare", value: KeyStore.foursquareKey == nil ? "鍵なし" : "迷ったときだけ")
                LabeledContent("OpenStreetMap", value: "迷ったときだけ")
                OSMCredit()
                if hasHotpepper {
                    LabeledContent("ホットペッパー", value: "使っています")
                    HotPepperCredit()
                    Button("ホットペッパーの鍵を外す", role: .destructive) { KeyStore.hotpepperKey = nil; hasHotpepper = false }
                } else {
                    SecureField("ホットペッパーグルメの鍵", text: $hotpepperKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存") {
                        KeyStore.hotpepperKey = hotpepperKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        hotpepperKey = ""
                        hasHotpepper = KeyStore.hotpepperKey != nil
                    }
                    .disabled(hotpepperKey.isEmpty)
                }
            } header: {
                Text("お店の候補を増やす")
            } footer: {
                Text(shopSourcesFooter)
            }
            Section {
                NavigationLink("試験（当たり方を比べる）") { EvalView() }
                NavigationLink("PC から取り込む（pCloud・Google フォト）") { PCImportView() }
                LabeledContent("訪問の記録", value: LocationWatch.shared.status == .authorizedAlways ? "\(VisitLog.load().count) 件" : "許可なし（「常に」が要る）")
                LabeledContent("今月 お店の写真と見比べた", value: "\(Metrics.value("lookAlikes")) 回")
            } header: {
                Text("精度")
            } footer: {
                Text("訪問の記録（どこに何分いたか）はこの iPhone の中だけに置き、AI には「何分いたか」だけを伝えます。お店の写真と見比べるのは、迷ったときだけです。")
            }
            Section {
                let s = AccuracyLog.summary(AccuracyLog.load())
                LabeledContent("合ってた", value: "\(s.hits)")
                LabeledContent("お店を直した（候補に入っていた）", value: "\(s.fixedInList)")
                LabeledContent("お店を直した（候補に無かった）", value: "\(s.fixedNotInList)")
                LabeledContent("お店ではなかった", value: "\(s.notShop)")
                LabeledContent("ジャンルを直した", value: "\(s.genreFixed)（うち端末だけで決めた \(s.genreFromPhoto)）")
                if let logURL {
                    ShareLink(item: logURL) { Label("外れ方の記録を送る", systemImage: "square.and.arrow.up") }
                } else {
                    Button("外れ方の記録を書き出す") { logURL = AccuracyLog.exportURL() }
                }
            } header: {
                Text("外れ方（これまで）")
            } footer: {
                Text("「候補に無かった」が多ければお店の候補の取り元を増やし、「候補に入っていた」が多ければ選び方を直します。")
            }
            Section {
                LabeledContent("今月 直した回数", value: "\(Metrics.value("corrections") + Metrics.value("dishEdits") + Metrics.value("genreEdits"))")
                LabeledContent("今月「合ってる」", value: "\(Metrics.value("confirmed"))")
                LabeledContent("今月 外した", value: "\(Metrics.value("hidden"))")
                LabeledContent("今月 分けた・くっつけた", value: "\(Metrics.value("splits") + Metrics.value("merges"))")
            } header: {
                Text("当たり具合（作る人のため）")
            }
            Section {
                Button("記録を全部消して読み直す", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("くわしい設定")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $giving) { KeyGiveView() }
        .confirmationDialog("記録を全部消しますか", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("全部消して読み直す", role: .destructive) { reset() }
        } message: {
            Text("お店の「また行きたい」とメモも消えます。写真は消えません。先にバックアップを作ると戻せます。")
        }
    }

    private func reset() {
        try? context.delete(model: Meal.self)
        try? context.delete(model: Place.self)
        try? context.save()
        SeenStore.reset()
        Spotlight.removeAll()
        Task { await Scanner.shared.scan() }
    }
}

/// 鍵を渡す（QR と 6 桁の数字。便1）
struct KeyGiveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = KeyHandoff.newCode()
    @State private var showCost = false
    @State private var cap = Spend.cap

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("受け取る人に費用を見せる", isOn: $showCost)
                    Stepper(value: $cap, in: 1...50) { LabeledContent("月の上限", value: String(format: "$%.0f", cap)) }
                }
                if let text = payloadText, let image = QR.image(text) {
                    Section {
                        VStack(spacing: 12) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260)
                            Text("数字: \(code)").font(.system(.title2, design: .monospaced).bold()).foregroundStyle(Ink.ai)
                            ShareLink(item: Image(uiImage: image), preview: SharePreview("ごはん帖の鍵", image: Image(uiImage: image))) {
                                Label("QR を画像で送る（数字は別に伝える）", systemImage: "square.and.arrow.up")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } footer: {
                        Text("相手のごはん帖で「設定 → AI の鍵を受け取る」を押し、この QR を読んで数字を入れてもらいます。数字は QR と別の方法で伝えてください。")
                    }
                }
            }
            .navigationTitle("鍵を渡す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private var payloadText: String? {
        let payload = KeyHandoff.Payload(key: ClaudeLink.usesRelay ? nil : KeyStore.claudeKey,
                                         relayURL: ClaudeLink.usesRelay ? AISettings.relayURL : nil,
                                         relayToken: ClaudeLink.usesRelay ? KeyStore.relayToken : nil,
                                         cap: cap, showCost: showCost,
                                         hotpepperKey: KeyStore.hotpepperKey, googleKey: KeyStore.googleKey)
        return KeyHandoff.seal(payload, code: code)
    }
}

/// 鍵を受け取る（カメラで読む・写真から読む。便1）
struct KeyReceiveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scanned: String?
    @State private var code = ""
    @State private var picked: PhotosPickerItem?
    @State private var message: String?
    @State private var camera = false

    var body: some View {
        NavigationStack {
            Form {
                if scanned == nil {
                    Section {
                        if DataScannerViewController.isSupported {
                            Button("カメラで QR を読む") { camera = true }
                        }
                        PhotosPicker(selection: $picked, matching: .images) { Text("写真（スクリーンショット）から読む") }
                    } footer: {
                        Text("LINE などで送られてきた QR の画像は、保存してから「写真から読む」で選べます。")
                    }
                } else {
                    Section {
                        TextField("6 桁の数字", text: $code).keyboardType(.numberPad)
                        Button("受け取る") { receive() }.disabled(code.count != 6)
                    } header: {
                        Text("QR を読みました")
                    }
                }
                if let message { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("鍵を受け取る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .sheet(isPresented: $camera) {
                QRScannerView { text in
                    camera = false
                    accept(text)
                }
                .ignoresSafeArea()
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let text = QR.read(data) {
                        accept(text)
                    } else {
                        message = "QR が見つかりませんでした"
                    }
                }
            }
        }
    }

    private func accept(_ text: String) {
        if text.hasPrefix(KeyHandoff.prefix) {
            scanned = text
            message = nil
        } else {
            message = "ごはん帖の QR ではありません"
        }
    }

    private func receive() {
        guard let scanned, let payload = KeyHandoff.open(scanned, code: code) else {
            message = "数字が違うようです"
            return
        }
        KeyHandoff.apply(payload)
        message = "受け取りました。次に写真を読むときから AI を使います。"
        Task {
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}

/// QR を作る・読む
enum QR {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func read(_ data: Data) -> String? {
        guard let image = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

/// カメラで QR を読む
struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        // 画面に出てからでないと読み始められないので、少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { try? controller.startScanning() }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}

/// おうち・職場の場所（便14・便15）
struct SpotsView: View {
    @State private var home = Spots.get("home")
    @State private var work = Spots.get("work")
    @State private var busy = false

    var body: some View {
        Form {
            spotSection("おうち", key: "home", value: $home)
            spotSection("職場・学校", key: "work", value: $work)
            Section {
                Text("ここから 150m 以内で撮ったごはんは、お店を探さずに「おうちごはん」「職場で」にします。場所はこの iPhone の中にだけ置きます。")
                    .font(.footnote).foregroundStyle(Ink.hai)
            }
        }
        .navigationTitle("おうち・職場")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func spotSection(_ title: String, key: String, value: Binding<CLLocationCoordinate2D?>) -> some View {
        Section(title) {
            if let c = value.wrappedValue {
                Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 400, longitudinalMeters: 400))) {
                    Marker(title, coordinate: c).tint(Ink.ai)
                }
                .frame(height: 140)
                Button("外す", role: .destructive) {
                    Spots.set(key, nil)
                    value.wrappedValue = nil
                }
            }
            Button(busy ? "調べています…" : "いまいる所を\(title)にする") {
                Task {
                    busy = true
                    if let here = await LocationWatch.shared.current() {
                        Spots.set(key, here.coordinate)
                        value.wrappedValue = here.coordinate
                    }
                    busy = false
                }
            }
            .disabled(busy)
        }
    }
}

/// 記念日（便65）
struct AnniversariesView: View {
    @State private var items = Anniversary.all
    @State private var name = ""
    @State private var date = Date()

    var body: some View {
        Form {
            Section {
                ForEach(items) { a in LabeledContent(a.name, value: "\(a.month)月\(a.day)日") }
                    .onDelete { offsets in
                        items.remove(atOffsets: offsets)
                        Anniversary.all = items
                    }
            } footer: {
                Text("この日のごはんには「記念日」の印が付きます。")
            }
            Section("足す") {
                TextField("名前（例: 付き合った日）", text: $name)
                DatePicker("日にち", selection: $date, displayedComponents: .date)
                Button("足す") {
                    let parts = Calendar.current.dateComponents([.month, .day], from: date)
                    items.append(Anniversary(name: name, month: parts.month ?? 1, day: parts.day ?? 1))
                    Anniversary.all = items
                    name = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("記念日")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 何を送っているか（便73）
struct PrivacyView: View {
    var body: some View {
        List {
            Section("この iPhone の中だけで見るもの") {
                Text("・写真が食べ物かどうか、写真の中の文字（看板・メニュー）")
                Text("・近くのお店（Apple のマップで探します）")
                Text("・おうち・職場の場所、予定表、記念日")
            }
            Section("AI（Anthropic の Claude）に送るもの") {
                Text("・1回の食事につき、料理の写真 3 枚までと、看板・メニューの写真 2 枚まで（小さくした JPEG）")
                Text("・撮った日時、だいたいの地名、お店の候補の名前と距離、写真から読めた文字、予定の名前（予定表を使うときだけ）")
                Text("・人の顔は、送る前に塗りつぶします（設定で変えられます）")
                Text("・お店に迷ったときだけ、街の名前・写真から読めた文字・料理のジャンルを送って、AI にネットで探してもらいます（設定で止められます）")
                Text("・お店に迷ったときだけ、候補のお店の紹介写真（ホットペッパー・Google）と料理の写真を見比べてもらいます")
                Text("・お店にいた時間（iPhone の訪問の記録から。場所の記録そのものはこの iPhone の中だけ）")
            }
            Section("鍵を入れたときだけ送るもの") {
                Text("・Google・ホットペッパーに、写真のだいたいの場所と、探すお店の名前")
            }
            Section("送らないもの") {
                Text("・写真の元のファイル、写真の正確な位置の数字、メモ、ほかの写真")
            }
            Section {
                Text("AI を使いたくないときは、「くわしい設定 → 端末だけで判定する」をオンにしてください。お店の当たりは下がりますが、何も送りません。")
                    .font(.footnote)
            }
        }
        .navigationTitle("何を送っているか")
        .navigationBarTitleDisplayMode(.inline)
    }
}
