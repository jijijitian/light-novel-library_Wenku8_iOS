import SwiftUI
import Wenku8Core

struct RankView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var selection: RankBoard = .dayvisit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RankBoardPicker(selection: $selection)
                NavigationLink {
                    RankListView(board: selection)
                } label: {
                    HStack {
                        Image(systemName: selection.symbol)
                        Text(selection.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote)
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 20)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "全部榜单", subtitle: "点击进入完整排行", symbol: "chart.bar")
                    ForEach(RankBoard.allCases) { board in
                        NavigationLink {
                            RankListView(board: board)
                        } label: {
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
                        }
                        .buttonStyle(.plain)
                        if board != RankBoard.allCases.last {
                            Divider().opacity(0.35)
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
}

struct RankBoardPicker: View {
    @Binding var selection: RankBoard

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainerWrapper(spacing: 10) {
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

/// `GlassEffectContainer` is iOS 26 only, so the picker falls back to a plain HStack.
struct GlassEffectContainerWrapper<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

@MainActor
final class RankListViewModel: ObservableObject {
    @Published private(set) var novels: [NovelSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published private(set) var needsLogin = false

    private let service: NovelService
    private var loadedBoards = Set<String>()

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(board: RankBoard, page: Int = 1, force: Bool = false) async {
        let key = "\(board.rawValue)-\(page)"
        guard force || !loadedBoards.contains(key) else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.rank(board, page: page)
            novels = result
            needsLogin = false
            error = nil
            loadedBoards.insert(key)
        } catch Wenku8Error.needLogin {
            needsLogin = true
            error = Wenku8Error.needLogin
        } catch {
            self.error = error
        }
    }
}

struct RankListView: View {
    var board: RankBoard
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = RankListViewModel()
    @State private var showWeb = false

    var body: some View {
        ScrollView {
            if model.isLoading && model.novels.isEmpty {
                LoadingRow()
            } else if let error = model.error, model.novels.isEmpty {
                VStack(spacing: 12) {
                    ErrorStateView(error: error) {
                        Task { await model.load(board: board, force: true) }
                    }
                    Button("在网页版查看") { showWeb = true }
                        .buttonStyle(.glass)
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
        .navigationTitle(board.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(board: board, force: true) }
        .task { await model.load(board: board) }
        .sheet(isPresented: $showWeb) {
            WebSheet(url: URL(string: "https://www.wenku8.net/wap/article/toplist.php?sort=\(board.rawValue)"))
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
