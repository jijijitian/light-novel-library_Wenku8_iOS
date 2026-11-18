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
    @Published private(set) var sugoiSections: [SugoiParser.Section] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published private(set) var needsLogin = false
    @Published private(set) var notice: String?

    private let service: NovelService
    private var loadedKeys = Set<String>()

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(board: RankBoard, year: Int = SugoiParser.availableYears[0], force: Bool = false) async {
        let key = "\(board.rawValue)-\(year)"
        guard force || !loadedKeys.contains(key) else { return }
        guard !isLoading else { return }
        isLoading = true
        notice = nil
        defer { isLoading = false }

        do {
            let result = try await service.rank(board, page: 1)
            novels = result
            sugoiSections = []
            needsLogin = false
            error = nil
            loadedKeys.insert(key)
        } catch Wenku8Error.needLogin {
            await loadSugoi(year: year, reason: "排行榜需要登录文库账号，先看看年度榜单")
            loadedKeys.insert(key)
        } catch {
            await loadSugoi(year: year, reason: "排行榜暂时不可用，已切换到年度榜单")
            if novels.isEmpty {
                self.error = error
            }
            loadedKeys.insert(key)
        }
    }

    func loadSugoi(year: Int, reason: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let parsed = try await service.sugoi(year: year)
            sugoiSections = parsed.sections
            novels = []
            error = nil
            needsLogin = false
            notice = reason.map { "\($0)（\(year) 年度）" }
        } catch {
            self.error = error
            sugoiSections = []
        }
    }

    var isEmpty: Bool {
        novels.isEmpty && sugoiSections.isEmpty
    }

    /// Whether the yearly list is what is on screen.
    ///
    /// The ranking itself is the normal case; the yearly boards are a fallback for when
    /// it cannot be served, and the year selector belongs only to them.
    var isShowingYearlyFallback: Bool {
        novels.isEmpty && !sugoiSections.isEmpty
    }
}

struct RankListView: View {
    var board: RankBoard
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = RankListViewModel()
    @State private var showWeb = false
    @State private var year = SugoiParser.availableYears[0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notice = model.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .glassCard(cornerRadius: 16)
                }

                // Only while the yearly list is what is on screen. The picker used to
                // sit above a normal ranking, so tapping a year silently replaced a
                // 日点击榜 with a 2025 年度榜 — a switch the reader never asked for and
                // could not undo, since the yearly boards have no other entry point.
                if model.isShowingYearlyFallback {
                    yearPicker
                }

                if model.isLoading && model.isEmpty {
                    LoadingRow()
                } else if let error = model.error, model.isEmpty {
                    VStack(spacing: 12) {
                        ErrorStateView(error: error) {
                            Task { await model.load(board: board, year: year, force: true) }
                        }
                        Button("在网页版查看") { showWeb = true }
                            .secondaryGlassButtonShape()
                    }
                } else if !model.novels.isEmpty {
                    NovelGrid(novels: model.novels) { novel in
                        router.open(.novel(novel.id))
                    }
                } else {
                    ForEach(model.sugoiSections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: section.caption, symbol: "trophy.fill")
                            NovelGrid(novels: section.novels) { novel in
                                router.open(.novel(novel.id))
                            }
                        }
                        .padding(14)
                        .glassCard(cornerRadius: 22)
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
        .refreshable { await model.load(board: board, year: year, force: true) }
        .task { await model.load(board: board, year: year) }
        .onChange(of: year) { _, newValue in
            // Changing the year only applies while the yearly list is showing; if a
            // normal ranking is up, switching years must not replace it.
            guard model.isShowingYearlyFallback else { return }
            Task { await model.loadSugoi(year: newValue) }
        }
        .sheet(isPresented: $showWeb) {
            WebSheet(url: URL(string: "https://www.wenku8.net/wap/article/toplist.php?sort=\(board.rawValue)"))
        }
    }

    /// The yearly-board selector, shown only when the yearly list is displayed.
    private var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(SugoiParser.availableYears, id: \.self) { value in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { year = value }
                        } label: {
                            Text("\(String(value))年度")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .glassCapsule(
                            tint: year == value ? AppTheme.accent.opacity(0.55) : nil,
                            interactive: true
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
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
