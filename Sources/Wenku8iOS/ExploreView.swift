import SwiftUI
import Wenku8Core

struct ExploreView: View {
    @EnvironmentObject private var router: AppRouter
    /// The website homepage's panels, shown above the boards.
    @State private var blocks: [DesktopParser.HomeBlock] = []
    @State private var isLoadingBlocks = false
    @State private var blocksError: Error?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                exploreBlocks

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

                        // Tags belong with browsing rather than with search: the site
                        // publishes them as a cloud, and each one opens a book list.
                        NavigationLink {
                            TagCloudView()
                        } label: {
                            boardRow(title: "标签", symbol: "number")
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
        .navigationTitle("探索")
        .task { await loadBlocks() }
        .refreshable { await Task { await loadBlocks(force: true) }.value }
    }

    // MARK: - Website homepage

    /// The website's own homepage panels.
    ///
    /// They need a session and they are website content, so relay-only mode says so in one
    /// short card instead of leaving a hole in the page.
    @ViewBuilder
    private var exploreBlocks: some View {
        if !blocks.isEmpty {
            ForEach(blocks) { block in
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: block.title, symbol: "sparkles")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(block.novels) { novel in
                                Button {
                                    router.open(.novel(novel.id))
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverCard(
                                            url: novel.coverURL,
                                            title: novel.title,
                                            width: 88,
                                            height: 124
                                        )
                                        Text(novel.title)
                                            .font(.caption2)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .frame(width: 88, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        } else if isLoadingBlocks {
            LoadingRow(text: "正在载入探索板块…")
        } else if let blocksError {
            VStack(alignment: .leading, spacing: 8) {
                Label("探索板块暂时无法载入", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
                Text((blocksError as? LocalizedError)?.errorDescription ?? "请稍后再试")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await loadBlocks(force: true) }
                } label: {
                    Label("重新载入", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .secondaryGlassButtonShape()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22)
        }
    }

    private func loadBlocks(force: Bool = false) async {
        if isLoadingBlocks && !force { return }
        isLoadingBlocks = true
        defer { isLoadingBlocks = false }
        do {
            blocks = try await NovelService().exploreBlocks()
            blocksError = nil
        } catch {
            if blocks.isEmpty { blocksError = error }
        }
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
            WebSheet(url: SiteDomain.current.webURL("/toplist.php?sort=\(board.rawValue)"))
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

