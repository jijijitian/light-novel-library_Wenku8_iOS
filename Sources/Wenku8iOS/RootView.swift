import SwiftUI
import Wenku8Core

struct RootView: View {
    @EnvironmentObject private var router: AppRouter

    enum Tab: Hashable {
        case home
        case rank
        case search
        case shelf
        case settings
    }

    var body: some View {
        // Uses the iOS 18+ `Tab` builder so iOS 26/27 renders Apple's own Liquid
        // Glass dock: the search tab gets the system `.search` role, which the
        // platform separates to the trailing edge and morphs into a search field.
        TabView(selection: tabSelection) {
            Tab("书架首页", systemImage: "house.fill", value: Tab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("排行", systemImage: "chart.bar.fill", value: Tab.rank) {
                NavigationStack(path: $router.rankPath) {
                    RankView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("搜索", systemImage: "magnifyingglass", value: Tab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("我的书架", systemImage: "books.vertical.fill", value: Tab.shelf) {
                NavigationStack(path: $router.shelfPath) {
                    ShelfView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("设置", systemImage: "gearshape.fill", value: Tab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }
        }
    }

    /// The search tab is selected by the system through a `TabRole`-driven value;
    /// keep the app's own `Tab` enum as the single source of truth.
    private var tabSelection: Binding<Tab> {
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
