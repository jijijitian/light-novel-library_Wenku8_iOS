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

                // The yearly boards used to be reachable only by tapping a year above a
                // normal ranking — an accidental switch rather than a destination. They
                // now have their own entry here, which is where a reader would look.
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        title: "年度排行",
                        subtitle: "按年份查看当年的完整榜单",
                        symbol: "trophy"
                    )
                    NavigationLink {
                        YearlyRankView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "trophy")
                                .font(.subheadline)
                                .frame(width: 26)
                                .foregroundStyle(.tint)
                            Text("年度排行")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        HStack(spacing: 12) {
            Image(systemName: board.symbol)
                .font(.subheadline)
                .frame(width: 26)
                .foregroundStyle(.tint)
            Text(board.title).font(.subheadline)
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
            ("其他", [.size, .anime]),
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

@MainActor
final class RankListViewModel: ObservableObject {
    @Published private(set) var novels: [NovelSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private let service: NovelService
    private var loadedBoard: RankBoard?

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    /// Loads one board.
    ///
    /// A board that cannot be served reports that; it is no longer silently replaced by
    /// a yearly list under the wrong title, which made "日点击榜" show 2025's board. The
    /// yearly boards have their own screen.
    func load(board: RankBoard, force: Bool = false) async {
        guard force || loadedBoard != board else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            novels = try await service.rank(board, page: 1)
            error = novels.isEmpty ? Wenku8Error.unavailable("这个榜单暂时没有数据") : nil
            loadedBoard = board
        } catch {
            novels = []
            self.error = error
        }
    }

    var isEmpty: Bool { novels.isEmpty }
}

struct RankListView: View {
    var board: RankBoard
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = RankListViewModel()
    @State private var showWeb = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isLoading && model.isEmpty {
                    LoadingRow()
                } else if let error = model.error, model.isEmpty {
                    VStack(spacing: 12) {
                        ErrorStateView(error: error) {
                            Task { await model.load(board: board, force: true) }
                        }
                        Button("在网页版查看") { showWeb = true }
                            .secondaryGlassButtonShape()
                    }
                } else {
                    NovelGrid(novels: model.novels) { novel in
                        router.open(.novel(novel.id))
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
        .refreshable { await model.load(board: board, force: true) }
        .task { await model.load(board: board) }
        .sheet(isPresented: $showWeb) {
            WebSheet(url: URL(string: "https://www.wenku8.net/wap/article/toplist.php?sort=\(board.rawValue)"))
        }
    }

    /// The yearly-board selector, shown only when the yearly list is displayed.
}

struct LibraryListView: View {
    var categoryID: Int
    var title: String

    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = LibraryListViewModel()

    var body: some View {
        ScrollView {
            if model.isLoading && model.novels.isEmpty {
                LoadingRow()
            } else if let error = model.error, model.novels.isEmpty {
                ErrorStateView(error: error) {
                    Task { await model.load(category: categoryID, force: true) }
                }
            } else {
                NovelGrid(novels: model.novels) { novel in
                    router.open(.novel(novel.id))
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
        }
        .background { AppBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(category: categoryID, force: true) }
        .task { await model.load(category: categoryID) }
    }
}

@MainActor
final class LibraryListViewModel: ObservableObject {
    @Published private(set) var novels: [NovelSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private let service: NovelService
    private var loaded = false

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(category: Int, force: Bool = false) async {
        guard force || !loaded else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            novels = try await service.library(category, page: 1)
            error = nil
            loaded = true
        } catch {
            self.error = error
        }
    }
}
