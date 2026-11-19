import SwiftUI
import Wenku8Core

struct RankView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // One way in. The board selector used to sit above a second row that
                // opened the *selected* board, and "全部榜单" listed every board again
                // — so 日点击榜 appeared three times on screen. Selecting a board now
                // opens it, and the grouped list is the single index of all boards.
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        title: "全部榜单",
                        subtitle: "点击任意榜单查看完整排行",
                        symbol: "chart.bar"
                    )
                    // 年度 first, as an ordinary row: it is a board like the others, not
                    // a separate section of the page.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("年度")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        NavigationLink {
                            YearlyRankView()
                        } label: {
                            boardRow(title: "年度排行", symbol: "trophy")
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(Self.groupedBoards, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(group.boards) { board in
                                NavigationLink {
                                    RankListView(board: board)
                                } label: {
                                    boardRow(board)
                                }
                                .buttonStyle(.plain)
                                if board != group.boards.last {
                                    Divider().opacity(0.35)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 22)

            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("排行榜")
    }

    private func boardRow(_ board: RankBoard) -> some View {
        boardRow(title: board.title, symbol: board.symbol)
    }

    /// One row in the board index.
    private func boardRow(title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .frame(width: 26)
                .foregroundStyle(.tint)
            Text(title).font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Boards grouped by period, which is how the site presents them: a click board
    /// and a recommendation board for each of day / week / month, plus the totals.
    private static var groupedBoards: [(title: String, boards: [RankBoard])] {
        [
            ("日榜", [.dayvisit, .dayvote]),
            ("周榜", [.weekvisit, .weekvote]),
            ("月榜", [.monthvisit, .monthvote]),
            ("总榜", [.allvisit, .allvote, .goodnum]),
            ("更新与入库", [.lastupdate, .postdate]),
            ("其他", [.size, .fullflag, .anime]),
        ].filter { !$0.1.isEmpty }
    }
}

struct RankBoardPicker: View {
    @Binding var selection: RankBoard

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(RankBoard.allCases) { board in
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { selection = board }
                        } label: {
                            Text(board.title)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .glassCapsule(
                            tint: selection == board ? AppTheme.accent.opacity(0.55) : nil,
                            interactive: true
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct RankListView: View {
    var board: RankBoard
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = PagedNovelListModel()
    @State private var showWeb = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.novels.isEmpty && model.isLoading {
                    LoadingRow()
                } else if let error = model.error, model.novels.isEmpty {
                    VStack(spacing: 12) {
                        ErrorStateView(error: error) { Task { await reload() } }
                        Button("在网页版查看") { showWeb = true }
                            .secondaryGlassButtonShape()
                    }
                } else {
                    PagedNovelGrid(model: model) { novelID in
                        router.open(.novel(novelID))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background { AppBackground() }
        .navigationTitle(board.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task { await reload() }
        .task { await debugAutoReloadIfRequested() }
        .sheet(isPresented: $showWeb) {
            WebSheet(url: URL(string: "https://www.wenku8.net/wap/article/toplist.php?sort=\(board.rawValue)"))
        }
    }

    private func reload() async {
        await model.start { page in
            try await NovelService().rankPage(board, page: page)
        }
    }

    /// Fires a reload whose runner is cancelled mid-flight, the way SwiftUI cancels a
    /// `.refreshable` closure, and logs what the list holds before and after.
    ///
    ///     --environment-variables '{"WENKU8_AUTO_REFRESH":"1"}'
    func debugAutoReloadIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["WENKU8_AUTO_REFRESH"] != nil else { return }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        print("[rank] before -> \(model.novels.prefix(3).map { $0.id })")
        let pull = Task { await model.reload() }
        pull.cancel()
        await pull.value
        print("[rank] after cancelled reload -> \(model.novels.prefix(3).map { $0.id })")
        #endif
    }

    /// The yearly-board selector, shown only when the yearly list is displayed.
}

struct LibraryListView: View {
    var categoryID: Int
    var title: String

    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = PagedNovelListModel()

    var body: some View {
        ScrollView {
            if model.novels.isEmpty && model.isLoading {
                LoadingRow()
            } else if let error = model.error, model.novels.isEmpty {
                ErrorStateView(error: error) {
                    Task { await reload() }
                }
            } else {
                PagedNovelGrid(model: model) { novelID in
                    router.open(.novel(novelID))
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
        }
        .background { AppBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task { await reload() }
    }

    private func reload() async {
        await model.start { page in
            try await NovelService().libraryPage(categoryID, page: page)
        }
    }
}

