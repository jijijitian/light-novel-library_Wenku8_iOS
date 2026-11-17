import SwiftUI
import Wenku8Core

struct RootView: View {
    @EnvironmentObject private var router: AppRouter

    enum AppTab: Hashable {
        case home
        case rank
        case search
        case shelf
        case settings
    }

    var body: some View {
        // On iOS 18+ the `Tab` builder is used, which is what lets iOS 26/27 render
        // Apple's own Liquid Glass dock — including the separated, morphing search
        // tab that the `.search` role produces. iOS 17 keeps the classic tabItem API.
        if #available(iOS 18.0, *) {
            modernTabs
        } else {
            legacyTabs
        }
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: tabSelection) {
            Tab("书架首页", systemImage: "house.fill", value: AppTab.home) {
                homeStack
            }
            Tab("排行", systemImage: "chart.bar.fill", value: AppTab.rank) {
                rankStack
            }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                searchStack
            }
            Tab("我的书架", systemImage: "books.vertical.fill", value: AppTab.shelf) {
                shelfStack
            }
            Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                settingsStack
            }
        }
    }

    private var legacyTabs: some View {
        TabView(selection: tabSelection) {
            homeStack
                .tabItem { Label("书架首页", systemImage: "house.fill") }
                .tag(AppTab.home)
            rankStack
                .tabItem { Label("排行", systemImage: "chart.bar.fill") }
                .tag(AppTab.rank)
            searchStack
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            shelfStack
                .tabItem { Label("我的书架", systemImage: "books.vertical.fill") }
                .tag(AppTab.shelf)
            settingsStack
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
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
