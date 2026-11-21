import Photos
import SwiftUI

/// 初めて開いたとき
struct OnboardingView: View {
    let done: () -> Void
    @State private var range = 30
    @State private var asking = false
    @State private var denied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("🍜").font(.system(size: 64))
                Text("ごはん帖").font(.largeTitle.bold())
                Text("いつも通りカメラでごはんを撮るだけで、どのお店で・何を食べたかを自動で記録します。メモは要りません。")
                VStack(alignment: .leading, spacing: 12) {
                    Label("写真の位置と時刻から、近くのお店を探します", systemImage: "mappin.and.ellipse")
                    Label("料理の写真と看板・メニューの文字から、お店と料理名を決めます", systemImage: "text.viewfinder")
                    Label("自信がないときだけ「たぶん」と付けます。直さなくても大丈夫です", systemImage: "checkmark.seal")
                    Label("写真はこのアプリにコピーしません。写真アプリのものを見るだけです", systemImage: "lock")
                }
                .font(.callout)

                VStack(alignment: .leading, spacing: 8) {
                    Text("どこまで前の写真から読みますか").font(.headline)
                    Picker("読む範囲", selection: $range) {
                        Text("1か月").tag(30)
                        Text("3か月").tag(90)
                        Text("1年").tag(365)
                        Text("3年").tag(1095)
                    }
                    .pickerStyle(.segmented)
                    Text("長くすると、初回の読み込みに時間がかかります（あとから設定で変えられます）")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if denied {
                    Text("写真を見る許可がありません。設定アプリ → ごはん帖 → 写真 で「フルアクセス」にしてください。")
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await start() }
                } label: {
                    Text("写真へのアクセスを許可して始める")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(asking)
            }
            .padding(24)
        }
    }

    private func start() async {
        asking = true
        defer { asking = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            denied = true
            return
        }
        await Notifier.ask()
        ScanSettings.since = Calendar.current.date(byAdding: .day, value: -range, to: Date()) ?? Date()
        done()
        Task { await Scanner.shared.scan() }
    }
}
