import AppIntents
import Foundation

// Siri・ショートカット・iPhone の検索から開く（便38）

struct OpenOneYearIntent: AppIntent {
    static var title: LocalizedStringResource = "1年前の今日を見る"
    static var description = IntentDescription("ごはん帖で、1年前の今日に食べたものを開きます")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.tab = .log
        Router.shared.showOneYear = true
        return .result()
    }
}

struct OpenWantIntent: AppIntent {
    static var title: LocalizedStringResource = "また行きたいお店を見る"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.tab = .want
        return .result()
    }
}

struct SearchMealsIntent: AppIntent {
    static var title: LocalizedStringResource = "ごはん帖で探す"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "ことば")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.tab = .log
        Router.shared.searchQuery = text
        return .result()
    }
}

struct GohanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenOneYearIntent(),
                    phrases: ["\(.applicationName)で1年前の今日", "\(.applicationName)の1年前の今日を見せて"],
                    shortTitle: "1年前の今日", systemImageName: "calendar")
        AppShortcut(intent: OpenWantIntent(),
                    phrases: ["\(.applicationName)でまた行きたいお店", "\(.applicationName)のまた行きたいを見せて"],
                    shortTitle: "また行きたい", systemImageName: "heart")
        AppShortcut(intent: SearchMealsIntent(),
                    phrases: ["\(.applicationName)で探す"],
                    shortTitle: "探す", systemImageName: "magnifyingglass")
    }
}
