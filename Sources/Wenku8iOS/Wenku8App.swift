import SwiftUI
import Wenku8Core

@main
struct Wenku8App: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .tint(AppTheme.accent)
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: RootView.Tab = .home
    @Published var homePath: [Route] = []
    @Published var rankPath: [Route] = []
    @Published var searchPath: [Route] = []
    @Published var shelfPath: [Route] = []
    @Published var settingsPath: [Route] = []

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
