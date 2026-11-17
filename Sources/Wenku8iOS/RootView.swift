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
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.homePath) {
                HomeView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("书架首页", systemImage: "house.fill") }
            .tag(Tab.home)

            NavigationStack(path: $router.rankPath) {
                RankView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("排行", systemImage: "chart.bar.fill") }
            .tag(Tab.rank)

            NavigationStack(path: $router.searchPath) {
                SearchView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack(path: $router.shelfPath) {
                ShelfView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("我的书架", systemImage: "books.vertical.fill") }
            .tag(Tab.shelf)

            NavigationStack {
                SettingsView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
            .tag(Tab.settings)
        }
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
