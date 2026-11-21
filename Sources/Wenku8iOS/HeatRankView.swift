import SwiftUI
import Wenku8Core

/// The site's heat ranking: twenty columns, one per library and per measure.
///
/// It is the page behind 热度排名 in the site's navigation, and like the tags it is website
/// content — the relay has no equivalent — so it is reachable only when the website is in use.
struct HeatRankView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var boards: [DesktopParser.HeatBoard] = []
    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        ScrollView {
            if isLoading && boards.isEmpty {
                LoadingRow(text: "正在载入热度排名…")
            } else if let error, boards.isEmpty {
                ErrorStateView(error: error) {
                    Task { await load(force: true) }
                }
            } else if boards.isEmpty {
                EmptyStateView(
                    symbol: "flame",
                    title: "暂时没有热度排名",
                    message: "站点没有返回榜单。"
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(boards) { board in
                        CoverPanel(
                            title: board.title,
                            novels: board.novels,
                            symbol: "flame",
                            onSelect: { router.open(.novel($0)) }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .background { AppBackground() }
        .navigationTitle("热度排名")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await Task { await load(force: true) }.value }
        .task {
            if boards.isEmpty { restore() }
            await load()
        }
    }

    // MARK: - Stored boards

    private struct Snapshot: Codable {
        var savedAt: Date
        var boards: [DesktopParser.HeatBoard]
    }

    private static var snapshotURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("HeatRankSnapshot.json")
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        boards = snapshot.boards
    }

    private func store() {
        guard !boards.isEmpty else { return }
        let snapshot = Snapshot(savedAt: Date(), boards: boards)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.snapshotURL, options: .atomic)
    }

    private func load(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        defer { isLoading = false }
        do {
            boards = try await NovelService().heatBoards()
            error = nil
            store()
        } catch {
            if boards.isEmpty { self.error = error }
        }
    }
}
