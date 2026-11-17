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

    /// Tabs are mounted lazily the first time they are visited, so a cold launch
    /// only performs the network work for the selected tab.
    @State private var mountedTabs: Set<AppTab> = [.home]

    var body: some View {
        tabContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isReading {
                    DockBar(selection: selection)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isReading)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onChange(of: router.tab) { _, newValue in
                mountedTabs.insert(newValue)
            }
    }

    /// All mounted stacks stay alive in a `ZStack` so each tab keeps its own
    /// navigation history, exactly like the system tab bar did.
    private var tabContent: some View {
        ZStack {
            ForEach(AppTab.allCases, id: \.self) { tab in
                if mountedTabs.contains(tab) {
                    stack(for: tab)
                        .opacity(router.tab == tab ? 1 : 0)
                        .allowsHitTesting(router.tab == tab)
                        .accessibilityHidden(router.tab != tab)
                }
            }
        }
    }

    @ViewBuilder
    private func stack(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack(path: $router.homePath) {
                HomeView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
        case .rank:
            NavigationStack(path: $router.rankPath) {
                RankView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
        case .search:
            NavigationStack(path: $router.searchPath) {
                SearchView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
        case .shelf:
            NavigationStack(path: $router.shelfPath) {
                ShelfView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
        case .settings:
            NavigationStack(path: $router.settingsPath) {
                SettingsView()
                    .navigationDestination(for: AppRouter.Route.self) { RouteView(route: $0) }
            }
        }
    }

    private var selection: Binding<AppTab> {
        Binding(
            get: { router.tab },
            set: { router.tab = $0 }
        )
    }

    /// The reader is a full-screen mode. Deriving this from the visible stack's
    /// path (rather than a flag toggled in `onAppear`) keeps the dock in sync
    /// with interactive back-swipe as well.
    private var isReading: Bool {
        if case .reader = currentPath.last { return true }
        return false
    }

    private var currentPath: [AppRouter.Route] {
        switch router.tab {
        case .home: return router.homePath
        case .rank: return router.rankPath
        case .search: return router.searchPath
        case .shelf: return router.shelfPath
        case .settings: return router.settingsPath
        }
    }
}

/// Hand-drawn replacement for the system tab bar, matching the target design:
/// an evenly divided row of icon-over-label items, no selection pill, the
/// selected item tinted in the app accent colour, and a hairline divider along
/// the top edge of the bar.
struct DockBar: View {
    @Binding var selection: RootView.AppTab

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 0.5)

            HStack(spacing: 0) {
                ForEach(RootView.AppTab.allCases, id: \.self) { tab in
                    item(for: tab)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
        .background(.bar)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func item(for tab: RootView.AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            guard selection != tab else { return }
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
