import SwiftUI
import Wenku8Core

struct RootView: View {
    @EnvironmentObject private var router: AppRouter

    enum AppTab: Hashable, CaseIterable {
        case home
        case rank
        case search
        case shelf
        case settings

        var title: String {
            switch self {
            case .home: return "书架首页"
            case .rank: return "排行"
            case .search: return "搜索"
            case .shelf: return "我的书架"
            case .settings: return "设置"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house.fill"
            case .rank: return "chart.bar.fill"
            case .search: return "magnifyingglass"
            case .shelf: return "books.vertical.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        // The system tab bar is used deliberately. On iOS 26/27 `TabView` renders
        // the floating Liquid Glass bar (the same one Music and App Store use),
        // including its glass capsule, selection highlight, scroll-minimise
        // behaviour and edge fades. A hand-drawn bar cannot reproduce that, and
        // the earlier attempt also had to fake navigation state to hide itself.
        //
        // The `Tab` builder needs iOS 18; iOS 17 keeps the classic tabItem API.
        if #available(iOS 18.0, *) {
            modernTabs
        } else {
            legacyTabs
        }
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: tabSelection) {
            Tab(AppTab.home.title, systemImage: AppTab.home.systemImage, value: AppTab.home) {
                homeStack
            }
            Tab(AppTab.rank.title, systemImage: AppTab.rank.systemImage, value: AppTab.rank) {
                rankStack
            }
            Tab(AppTab.search.title, systemImage: AppTab.search.systemImage, value: AppTab.search) {
                searchStack
            }
            Tab(AppTab.shelf.title, systemImage: AppTab.shelf.systemImage, value: AppTab.shelf) {
                shelfStack
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                settingsStack
            }
        }
    }

    private var legacyTabs: some View {
        TabView(selection: tabSelection) {
            homeStack
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.systemImage) }
                .tag(AppTab.home)
            rankStack
                .tabItem { Label(AppTab.rank.title, systemImage: AppTab.rank.systemImage) }
                .tag(AppTab.rank)
            searchStack
                .tabItem { Label(AppTab.search.title, systemImage: AppTab.search.systemImage) }
                .tag(AppTab.search)
            shelfStack
                .tabItem { Label(AppTab.shelf.title, systemImage: AppTab.shelf.systemImage) }
                .tag(AppTab.shelf)
            settingsStack
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
    }

    private var homeStack: some View {
        NavigationStack(path: $router.homePath) {
            HomeView()
                .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
        }
    }

    private var rankStack: some View {
        NavigationStack(path: $router.rankPath) {
            RankView()
                .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
        }
    }

    private var searchStack: some View {
        NavigationStack(path: $router.searchPath) {
            SearchView()
                .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
        }
    }

    private var shelfStack: some View {
        NavigationStack(path: $router.shelfPath) {
            ShelfView()
                .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
        }
    }

    private var settingsStack: some View {
        NavigationStack(path: $router.settingsPath) {
            SettingsView()
                .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
        }
    }

    /// Keeps the app's own tab enum as the single source of truth for selection.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { router.tab },
            set: { router.tab = $0 }
        )
    }
}

struct RouteView: View {
    var route: AppRouter.Route

    var body: some View {
        switch route {
        case .novel(let id):
            NovelDetailView(novelID: id)
        case .reader(let novelID, let chapters, let startIndex):
            ReaderView(novelID: novelID, chapters: chapters, startIndex: startIndex)
        case .reviews(let id):
            ReviewListView(novelID: id)
        case .rankList(let board):
            RankListView(board: board)
        case .library(let id, let name):
            LibraryListView(categoryID: id, title: name)
        }
    }
}

#if DEBUG
extension RootView.AppTab {
    /// Maps the `WENKU8_START_TAB` debug launch value onto a tab.
    init?(launchToken raw: String) {
        switch raw.lowercased() {
        case "home", "0": self = .home
        case "rank", "1": self = .rank
        case "search", "2": self = .search
        case "shelf", "3": self = .shelf
        case "settings", "4": self = .settings
        default: return nil
        }
    }
}
#endif
