import CoreSpotlight
import SwiftData
import SwiftUI

@main
struct GohanApp: App {
    let container: ModelContainer

    init() {
        // 初回は保存先のフォルダが無く、CoreData が「見つからない」と記録に出す（CI のテストで見えた）。先に作っておく
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        do {
            container = try ModelContainer(for: Meal.self, Place.self)
        } catch {
            // 記録の形が読めないときは、落ちずに空の記録で開く（写真はそのまま。読み直せば戻る）
            container = try! ModelContainer(for: Meal.self, Place.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        Scanner.shared.container = container
        Scanner.registerBackground()
        Net.shared.start()
        Brush.shared.load()
        LocationWatch.shared.start()
        NotificationRouter.shared.start()
        PartnerStore.shared.load()
        Slowness.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Ink.ai)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.modelContext) private var context
    @State private var onboarded = ScanSettings.onboarded
    @State private var scanner = Scanner.shared
    @State private var router = Router.shared
    @State private var undo = UndoCenter.shared
    @State private var locked = FaceLock.enabled
    @State private var importMessage: String?
    /// 共有ボタンから届いた文（大18）
    @State private var shared: SharedText?

    struct SharedText: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Group {
            if onboarded {
                TabView(selection: $router.tab) {
                    TimelineView()
                        .onAppear { Slowness.shared.appeared("きろく") }
                        .tabItem { Label("きろく", systemImage: "book.closed") }
                        .tag(Router.Tab.log)
                    WantView()
                        .onAppear { Slowness.shared.appeared("また行きたい") }
                        .tabItem { Label("また行きたい", systemImage: "heart") }
                        .tag(Router.Tab.want)
                    PlacesMapView()
                        .onAppear { Slowness.shared.appeared("地図") }
                        .tabItem { Label("地図", systemImage: "map") }
                        .tag(Router.Tab.map)
                }
            } else {
                OnboardingView {
                    ScanSettings.onboarded = true
                    onboarded = true
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = undo.message {
                UndoToast(message: message)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: undo.message)
        .overlay {
            if locked { LockView { locked = false } }
        }
        .onChange(of: phase) { _, new in
            if new == .active {
                PhotoWatch.shared.start()
                // お店で過ごした場所と時間を記録する許可を、1回だけ聞く（精度1）
                if onboarded { LocationWatch.shared.askAlwaysOnce() }
                if onboarded, ScanSettings.auto { Task { await scanner.scan() } }
                _ = Backup.remapMissing(context: context)
                if onboarded { takeShared() }
                Task { await WidgetFeed.write(context: context) }
            }
            if new == .background {
                Scanner.scheduleBackground()
                if FaceLock.enabled { locked = true }
            }
        }
        .onChange(of: router.tab) { _, _ in Slowness.shared.mark() }
        .onOpenURL { url in open(url) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let uuid = UUID(uuidString: id) {
                router.tab = .log
                router.openMeal = uuid
            }
        }
        .sheet(item: $shared) { AddWishView(initial: $0.text) }
        .alert("ふたり帖", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    /// 共有ボタンから届いた分を、行ってみたいの画面で開く（大18）
    private func takeShared() {
        let texts = ShareInbox.take()
        guard let last = texts.last else { return }
        router.tab = .want
        shared = SharedText(text: last)
    }

    /// .gohan（ふたり帖）や バックアップのファイルを開いたとき
    private func open(_ url: URL) {
        if url.scheme == "gohan" {
            // ホーム画面の小窓から（大19）
            if url.host == "meal", let id = UUID(uuidString: url.lastPathComponent) {
                router.tab = .log
                router.openMeal = id
            } else if url.host == "place",
                      let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value {
                router.tab = .want
                router.openPlace = key
            }
            return
        }
        if url.pathExtension == "gohan" {
            do {
                let count = try PartnerStore.shared.receive(url, context: context)
                importMessage = "\(count) 食を受け取りました。きろくの右上「…」→「ふたり」で見られます。"
            } catch {
                importMessage = "読めませんでした: \(error.localizedDescription)"
            }
        } else if url.pathExtension == "json" {
            do {
                let added = try Backup.restore(from: url, context: context)
                importMessage = "バックアップから \(added) 食を戻しました。"
            } catch {
                importMessage = "バックアップを読めませんでした: \(error.localizedDescription)"
            }
        }
    }
}

/// 「元に戻す」の帯
struct UndoToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Text(message).font(.subheadline).foregroundStyle(Ink.onAi).lineLimit(2)
            Spacer(minLength: 8)
            Button("元に戻す") { UndoCenter.shared.undo() }
                .font(.subheadline.bold())
                .foregroundStyle(Ink.onAi)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Ink.ai, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// Face ID で開く（便74）
struct LockView: View {
    let unlocked: () -> Void

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("ごはん帖").font(.brush(34, relativeTo: .largeTitle)).foregroundStyle(Ink.ai)
                Button("ひらく") { Task { await tryUnlock() } }
                    .buttonStyle(InkButtonStyle())
                    .frame(width: 200)
            }
        }
        .task { await tryUnlock() }
    }

    private func tryUnlock() async {
        if await FaceLock.unlock() { unlocked() }
    }
}
