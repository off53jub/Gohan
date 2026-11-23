import Photos
import SwiftUI

/// 初めて開いたとき（デ16・便3・便4・便5）
struct OnboardingView: View {
    let done: () -> Void
    @State private var step = Step.hello
    @State private var range = 90
    @State private var asking = false
    @State private var denied = false
    @State private var limited = false
    @State private var locationRatio: Double?
    @State private var scanner = Scanner.shared

    enum Step { case hello, gathering }

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            switch step {
            case .hello: hello
            case .gathering: gathering
            }
        }
    }

    private var hello: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Ink.ai)
                    .accessibilityHidden(true)
                Text("ごはん帖").font(.brush(40, relativeTo: .largeTitle)).foregroundStyle(Ink.ai)
                Text("いつも通りカメラでごはんを撮るだけで、どのお店で・何を食べたかを、帖に書きとめます。メモは要りません。")
                    .foregroundStyle(Ink.sumi)
                VStack(alignment: .leading, spacing: 12) {
                    Label("写真の場所と時刻から、近くのお店を探します", systemImage: "mappin.and.ellipse")
                    Label("料理の写真と看板・メニューの文字から、お店と料理名を決めます", systemImage: "text.viewfinder")
                    Label("自信がないときだけ「たぶん」と書きます。直さなくても大丈夫です", systemImage: "checkmark.seal")
                    Label("写真はこのアプリにコピーしません。写真アプリのものを見るだけです", systemImage: "lock")
                }
                .font(.callout)
                .foregroundStyle(Ink.sumi)

                VStack(alignment: .leading, spacing: 8) {
                    Text("どこまで前の写真から読みますか").font(.headline).foregroundStyle(Ink.ai)
                    Picker("読む範囲", selection: $range) {
                        Text("1か月").tag(30)
                        Text("3か月").tag(90)
                        Text("1年").tag(365)
                        Text("3年").tag(1095)
                    }
                    .pickerStyle(.segmented)
                    Text("長くすると、初めの読み込みに時間がかかります。古い写真は充電中に少しずつ読みます。")
                        .font(.caption).foregroundStyle(Ink.hai)
                }

                if denied {
                    Text("写真を見る許可がありません。設定アプリ → ごはん帖 → 写真 で「フルアクセス」にしてください。")
                        .font(.footnote).foregroundStyle(Ink.aka)
                }

                Button {
                    Task { await start() }
                } label: {
                    Text("写真を見る許可をして、はじめる")
                }
                .buttonStyle(InkButtonStyle())
                .disabled(asking)
            }
            .padding(24)
        }
    }

    /// 過去の写真から集めている様子（1枚ずつ帖に入る）
    private var gathering: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(scanner.isRunning ? "帖に書きとめています" : "ここまで書きとめました")
                .font(.brush(24, relativeTo: .title2)).foregroundStyle(Ink.ai)
            ZStack {
                ForEach(Array(scanner.recentPhotoIDs.prefix(6).enumerated()), id: \.element) { i, id in
                    PhotoThumb(id: id, side: 120, corner: 16)
                        .rotationEffect(.degrees(Double(i % 3 - 1) * 6))
                        .offset(x: CGFloat(i % 3 - 1) * 18, y: CGFloat(i) * -4)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(height: 180)
            .animation(.spring(duration: 0.5), value: scanner.recentPhotoIDs)
            Text("\(scanner.found) 食みつけました").font(.title3.bold()).foregroundStyle(Ink.sumi)
            if scanner.isRunning {
                Text(scanner.status).font(.footnote).foregroundStyle(Ink.hai)
            }
            if limited {
                Text("「選んだ写真だけ」の許可なので、選んだ写真の中から探しています。あとで設定から足せます。")
                    .font(.footnote).foregroundStyle(Ink.hai).multilineTextAlignment(.center)
            }
            if let ratio = locationRatio, ratio < 0.5 {
                Text("最近の写真の多くに場所が入っていません。お店を当てるには、カメラの位置情報をオンにしてください（設定アプリ → プライバシーとセキュリティ → 位置情報サービス → カメラ）。")
                    .font(.footnote).foregroundStyle(Ink.aka).multilineTextAlignment(.center)
            }
            Spacer()
            Button(scanner.isRunning ? "続きは読みながら見る" : "帖をひらく") { done() }
                .buttonStyle(InkButtonStyle())
            Text("途中で閉じても、続きから読みます。終わったらお知らせします。").font(.caption).foregroundStyle(Ink.hai)
        }
        .padding(24)
    }

    private func start() async {
        asking = true
        defer { asking = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            denied = true
            return
        }
        limited = status == .limited
        await Notifier.ask()
        ScanSettings.since = Calendar.current.date(byAdding: .day, value: -range, to: Date()) ?? Date()
        locationRatio = LocationCheck.ratio()
        PhotoWatch.shared.start()
        withAnimation { step = .gathering }
        Task { await Scanner.shared.scan() }
    }
}
