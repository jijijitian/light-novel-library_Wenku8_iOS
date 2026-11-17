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
        // Uses the iOS 18+ `Tab` builder so iOS 26/27 renders Apple's own Liquid
        // Glass dock: the search tab gets the system `.search` role, which the
        // platform separates to the trailing edge and morphs into a search field.
        TabView(selection: tabSelection) {
            Tab("书架首页", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("排行", systemImage: "chart.bar.fill", value: AppTab.rank) {
                NavigationStack(path: $router.rankPath) {
                    RankView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("我的书架", systemImage: "books.vertical.fill", value: AppTab.shelf) {
                NavigationStack(path: $router.shelfPath) {
                    ShelfView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }

            Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                NavigationStack(path: $router.settingsPath) {
                    SettingsView()
                        .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
                }
            }
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
