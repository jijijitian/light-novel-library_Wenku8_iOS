import SwiftUI
import Wenku8Core

@main
struct Wenku8App: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var router = AppRouter()
    @StateObject private var account = AccountStore()
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    /// Seeds the stored appearance from `WENKU8_APPEARANCE=light|dark|system` once,
    /// so a debug launch can open in a given mode.
    ///
    /// It must not be an override: reading the environment on every render made the
    /// setting unchangeable for the life of the process, since the variable always
    /// won over whatever the user picked in Settings.
    private static func seedAppearanceFromEnvironment() {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["WENKU8_APPEARANCE"],
              AppAppearance(rawValue: raw) != nil else { return }
        UserDefaults.standard.set(raw, forKey: AppAppearance.storageKey)
        #endif
    }

    /// Seeds the cover-tint switch from `WENKU8_COVER_TINT=1|0` once, so a debug launch can
    /// show the tinted detail page without driving Settings by hand.
    private static func seedCoverTintFromEnvironment() {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["WENKU8_COVER_TINT"] else { return }
        UserDefaults.standard.set(raw == "1", forKey: CoverPalette.storageKey)
        #endif
    }

    /// Seeds the relay switch from `WENKU8_RELAY=1|0` once, so a debug launch can reproduce
    /// the paths that only run with the relay on or off.
    private static func seedRelayFromEnvironment() {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["WENKU8_RELAY"] else { return }
        let store = RelayCredentialStore.shared
        store.setEnabled(raw == "1")
        if let hybrid = ProcessInfo.processInfo.environment["WENKU8_HYBRID"] {
            store.setHybridEnabled(hybrid == "1")
        }
        #endif
    }

    /// Debug-only: fetches a URL with the app's own session and writes the body to
    /// `Documents/dump.html`, so page markup can be inspected without driving the UI.
    private static func dumpURLFromEnvironment() {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["WENKU8_DUMP_URL"],
              let url = URL(string: raw) else { return }
        Task {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            guard let response = try? await Wenku8Client.shared.send(request) else {
                print("[dump] request failed")
                return
            }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let file = directory.appendingPathComponent("dump.html")
            try? response.data.write(to: file)
            let text = response.text
            let links = text.components(separatedBy: "/book/").count - 1
            print("[dump] status=\(response.status) bytes=\(response.data.count) bookLinks=\(links)")
            print("[dump] finalURL=\(response.finalURL?.absoluteString ?? "nil")")
        }
        #endif
    }

    init() {
        Self.dumpURLFromEnvironment()
        Self.seedRelayFromEnvironment()
        Self.seedAppearanceFromEnvironment()
        Self.seedCoverTintFromEnvironment()
        Self.configureRelay()
        Self.restoreDomain()
        Self.applyReaderOverrides()
    }

    /// Debug-only: forces reader settings from the environment so a launch can
    /// exercise a specific layout without hand-driving Settings. Writing the
    /// preference through `UserDefaults` is not reliable while the app runs
    /// (cfprefsd owns the file), so the override is applied in-process instead.
    private static func applyReaderOverrides() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let layout = env["WENKU8_READER_LAYOUT"],
           ReaderLayout(rawValue: layout) != nil {
            UserDefaults.standard.set(layout, forKey: ReaderPreferences.layoutKey)
        }
        if let indent = env["WENKU8_READER_INDENT"] {
            UserDefaults.standard.set(indent == "1", forKey: ReaderPreferences.indentKey)
        }
        #endif
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
            RelayConfiguration(isEnabled: enabled, isHybrid: settings.isHybridEnabled),
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
                // Applies the app-wide appearance chosen in Settings; the reader's
                // own palettes are unaffected.
                .preferredColorScheme(
                    (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
                )
                .task {
                    #if DEBUG
                    await account.debugSignInIfConfigured()
                    #endif
                }
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
    ///     --environment-variables '{"WENKU8_START_TAB":"settings"}' <udid> org.jijijitian.wenku8.ios
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
        // `WENKU8_OPEN_BOARD=dayvisit` opens a ranking directly, so its list and its
        // refresh can be exercised without driving the UI by hand.
        if let raw = ProcessInfo.processInfo.environment["WENKU8_OPEN_BOARD"],
           let board = RankBoard(rawValue: raw) {
            self.tab = .rank
            rankPath = [.rankList(board)]
        }
        // `WENKU8_OPEN_NOVEL=aid` opens a book's detail page directly, so the catalogue
        // can be inspected without driving the UI by hand.
        if let raw = ProcessInfo.processInfo.environment["WENKU8_OPEN_NOVEL"],
           let aid = Int(raw) {
            homePath = [.novel(aid)]
        }
        // `WENKU8_OPEN_TAG_CLOUD=1` opens Tags云集 directly.
        if ProcessInfo.processInfo.environment["WENKU8_OPEN_TAG_CLOUD"] != nil {
            rankPath = [.tagCloud]
        }
        // `WENKU8_OPEN_RANK_BOARDS=1` opens the board index directly.
        if ProcessInfo.processInfo.environment["WENKU8_OPEN_RANK_BOARDS"] != nil {
            rankPath = [.rankBoards]
        }
        // `WENKU8_OPEN_HEAT=1` opens the heat ranking directly.
        if ProcessInfo.processInfo.environment["WENKU8_OPEN_HEAT"] != nil {
            rankPath = [.heatRank]
        }
        // `WENKU8_OPEN_TAG=校园` opens a tag's book list directly.
        if let raw = ProcessInfo.processInfo.environment["WENKU8_OPEN_TAG"], !raw.isEmpty {
            homePath = [.tag(raw)]
        }
        // `WENKU8_OPEN_REVIEWS=aid` opens a book's review list directly, the same way.
        if let raw = ProcessInfo.processInfo.environment["WENKU8_OPEN_REVIEWS"],
           let aid = Int(raw) {
            homePath = [.novel(aid), .reviews(aid)]
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
        case tag(String)
        case rankBoards
        case tagCloud
        case yearlyRank
        case libraryBrowse
        case heatRank
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
