import SwiftData
import SwiftUI

@main
struct GohanApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Meal.self, Place.self)
        } catch {
            // 記録の形が読めないときは、落ちずに空の記録で開く（写真はそのまま。読み直せば戻る）
            container = try! ModelContainer(for: Meal.self, Place.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        Scanner.shared.container = container
        Scanner.registerBackground()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var phase
    @State private var onboarded = ScanSettings.onboarded
    @State private var scanner = Scanner.shared

    var body: some View {
        Group {
            if onboarded {
                TabView {
                    TimelineView()
                        .tabItem { Label("記録", systemImage: "fork.knife") }
                    PlacesMapView()
                        .tabItem { Label("地図", systemImage: "map") }
                    PlacesView()
                        .tabItem { Label("お店", systemImage: "heart.text.square") }
                    SettingsView()
                        .tabItem { Label("設定", systemImage: "gearshape") }
                }
            } else {
                OnboardingView {
                    ScanSettings.onboarded = true
                    onboarded = true
                }
            }
        }
        .onChange(of: phase) { _, new in
            if new == .active, onboarded, ScanSettings.auto {
                Task { await scanner.scan() }
            }
            if new == .background { Scanner.scheduleBackground() }
        }
    }
}
