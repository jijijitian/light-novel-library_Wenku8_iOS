import SwiftUI
import Wenku8Core

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var keyword = ""
    @Published var field: SearchQuery.Field = .title
    @Published private(set) var results: [NovelSummary] = []
    /// Paged results. Search can return hundreds of books; the old single fetch only ever
    /// showed the first page.
    let pages = PagedNovelListModel()
    @Published private(set) var isSearching = false
    @Published private(set) var error: Error?
    @Published private(set) var hasSearched = false

    private let service: NovelService
    private var task: Task<Void, Never>?

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func submit() {
        let query = SearchQuery(keyword: keyword, field: field)
        let trimmed = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        task = Task { [weak self] in
            await self?.perform(query)
        }
    }

    func search(history entry: LibraryStore.SearchHistoryEntry) {
        keyword = entry.keyword
        field = SearchQuery.Field(rawValue: entry.field) ?? .title
        submit()
    }

    func perform(_ query: SearchQuery) async {
        guard !isSearching else { return }
        isSearching = true
        error = nil
        defer { isSearching = false }
        await pages.start { page in
            try await self.service.searchPage(query, page: page)
        }
        results = pages.novels
        if pages.novels.isEmpty, let failure = pages.error {
            self.error = failure
        }
        hasSearched = true
    }

    func clear() {
        task?.cancel()
        results = []
        error = nil
        hasSearched = false
    }
}

struct SearchView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var model = SearchViewModel()
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchBar
                if model.isSearching && model.results.isEmpty {
                    LoadingRow(text: "正在搜索…")
                } else if let error = model.error, model.results.isEmpty {
                    ErrorStateView(error: error) { model.submit() }
                } else if model.hasSearched && model.results.isEmpty {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: "没有找到结果",
                        message: "换一个关键词，或者切换成按作者搜索试试。"
                    )
                } else if !model.results.isEmpty {
                    SectionHeader(
                        title: "搜索结果",
                        subtitle: "共 \(model.pages.novels.count) 本",
                        symbol: "sparkle.magnifyingglass"
                    )
                    PagedNovelList(model: model.pages) { novelID in
                        router.open(.novel(novelID))
                    }
                    .padding(12)
                    .glassCard(cornerRadius: 22)
                } else {
                    historySection
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("搜索")
        .onChange(of: model.keyword) { _, newValue in
            if newValue.isEmpty { model.clear() }
        }
    }

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("输入书名或作者", text: $model.keyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit(submit)
                if !model.keyword.isEmpty {
                    Button {
                        model.keyword = ""
                        model.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .glassCard(cornerRadius: 18)

            HStack(spacing: 10) {
                ForEach(SearchQuery.Field.allCases) { item in
                    Button {
                        model.field = item
                    } label: {
                        Text(item.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(
                        tint: model.field == item ? AppTheme.accent.opacity(0.5) : nil,
                        interactive: true
                    )
                }
                Spacer()
                Button(action: submit) {
                    Label("搜索", systemImage: "arrow.right.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .prominentGlassButtonShape()
                .tint(AppTheme.accent)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "搜索历史", symbol: "clock.arrow.circlepath")
                    Button("清空") { store.clearHistory() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 8) {
                    ForEach(store.history) { entry in
                        Button {
                            model.search(history: entry)
                        } label: {
                            Text(entry.keyword)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .glassCapsule(interactive: true)
                    }
                }
            }
            .padding(14)
            .glassCard(cornerRadius: 22)
        }
    }

    private func submit() {
        focused = false
        guard !model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.remember(keyword: model.keyword, field: model.field)
        model.submit()
    }
}

/// A minimal wrapping layout so chips flow instead of clipping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let current = rows[rows.count - 1]
            if current > 0 && current + spacing + size.width > maxWidth {
                rows.append(size.width)
                rowHeights.append(size.height)
            } else {
                rows[rows.count - 1] = current == 0 ? size.width : current + spacing + size.width
                rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            }
        }
        let height = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        return CGSize(width: maxWidth == .infinity ? rows.max() ?? 0 : maxWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
