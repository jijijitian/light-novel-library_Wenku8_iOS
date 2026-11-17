import SwiftUI
import Wenku8Core

@main
struct Wenku8App: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var router = AppRouter()
    @StateObject private var account = AccountStore()

    init() {
        Self.configureRelay()
        Self.restoreDomain()
    }

    /// Applies the mirror chosen in Settings before any request goes out.
    private static func restoreDomain() {
        let raw = UserDefaults.standard.string(forKey: "site.domain") ?? SiteDomain.net.rawValue
        Wenku8Client.shared.use(domain: SiteDomain(rawValue: raw) ?? .net)
    }

    /// The relay is the only path that serves real rankings and category
    /// listings anonymously, so it is enabled by default; the token is derived
    /// locally (`RelayAppVer`) and every call falls back to WAP/desktop on
    /// failure. Users can still switch it off in Settings.
    private static func configureRelay() {
        let settings = RelayCredentialStore.shared
        let enabled = settings.isEnabled
        RelayClient.shared.configure(
            RelayConfiguration(isEnabled: enabled),
            provider: enabled ? BuiltinAppVerProvider() : nil
        )
        if enabled {
            let interval = settings.minimumInterval
            Task { await RelayClient.shared.setMinimumInterval(interval) }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(account)
                .tint(AppTheme.accent)
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: RootView.AppTab
    @Published var homePath: [Route] = []
    @Published var rankPath: [Route] = []
    @Published var searchPath: [Route] = []
    @Published var shelfPath: [Route] = []
    @Published var settingsPath: [Route] = []

    /// The initial tab can be forced with `WENKU8_START_TAB` so a debug launch can
    /// open a specific screen without hand-driving the UI:
    ///   devicectl device process launch --terminate-existing \
    ///     --environment-variables '{"WENKU8_START_TAB":"settings"}' <udid> org.mewx.wenku8.ios
    /// The value is ignored in release builds.
    init(tab: RootView.AppTab? = nil) {
        self.tab = tab ?? Self.launchTab
        #if DEBUG
        // `WENKU8_OPEN_CHAPTER=aid:cid` jumps straight into the reader, which is
        // needed to inspect the reader without hand-driving the UI. The chapter
        // list is empty here, so `ReaderView` shows the chapter it just loaded
        // instead of a placeholder title.
        if let raw = ProcessInfo.processInfo.environment["WENKU8_OPEN_CHAPTER"],
           let colon = raw.firstIndex(of: ":"),
           let aid = Int(raw[raw.startIndex..<colon]),
           let cid = Int(raw[raw.index(after: colon)...]) {
            homePath = [.reader(novelID: aid, chapters: [ChapterLink(id: cid, title: "")], startIndex: 0)]
        }
        #endif
    }

    private static var launchTab: RootView.AppTab {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["WENKU8_START_TAB"],
           let tab = RootView.AppTab(launchToken: raw) {
            return tab
        }
        #endif
        return .home
    }

    enum Route: Hashable {
        case novel(Int)
        case reader(novelID: Int, chapters: [ChapterLink], startIndex: Int)
        case reviews(Int)
        case rankList(RankBoard)
        case library(Int, String)
    }

    func open(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .rank: rankPath.append(route)
        case .search: searchPath.append(route)
        case .shelf: shelfPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }
}

enum AppTheme {
    static let accent = Color(red: 0.34, green: 0.47, blue: 0.94)

    static func gradient(for id: Int) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.36, green: 0.45, blue: 0.92), Color(red: 0.62, green: 0.42, blue: 0.90)],
            [Color(red: 0.95, green: 0.55, blue: 0.42), Color(red: 0.86, green: 0.36, blue: 0.56)],
            [Color(red: 0.22, green: 0.68, blue: 0.66), Color(red: 0.28, green: 0.50, blue: 0.84)],
            [Color(red: 0.98, green: 0.72, blue: 0.38), Color(red: 0.92, green: 0.45, blue: 0.38)],
        ]
        let palette = palettes[abs(id) % palettes.count]
        return LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
