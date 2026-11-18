import SwiftUI
import Wenku8Core

/// A novel list that loads more as the reader scrolls, following the Android app.
///
/// The Android project loads the next page when the last-but-one row becomes visible and
/// shows "正在载入列表 (4/436)". The same rules apply here: the trigger is proximity to the
/// end rather than an explicit button, the reported page number tells the reader where
/// they are in a list that may run to hundreds of pages, and a page that arrives while
/// the list is already at the bottom re-triggers the check so the list cannot stall.
@MainActor
final class PagedNovelListModel: ObservableObject {
    @Published private(set) var novels: [NovelSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: Error?

    /// Pages fetched so far, and the total the source reports (nil when it does not).
    @Published private(set) var loadedPages = 0
    @Published private(set) var totalPages: Int?

    private var loadPage: ((Int) async throws -> NovelListPage)?
    /// Ids already present, so a page that overlaps the previous one does not duplicate.
    private var seen = Set<Int>()

    var hasMore: Bool {
        guard let totalPages else { return true }
        return loadedPages < totalPages
    }

    /// Status line shown while a page is in flight, e.g. "正在载入列表 4/426".
    var progressText: String? {
        guard isLoadingMore else { return nil }
        if let totalPages {
            return "正在载入列表 \(loadedPages + 1)/\(totalPages)"
        }
        return "正在载入列表……"
    }

    /// Starts a fresh list.
    func start(_ loader: @escaping (Int) async throws -> NovelListPage) async {
        loadPage = loader
        novels = []
        seen = []
        loadedPages = 0
        totalPages = nil
        error = nil
        await loadNext()
    }

    /// Loads the next page, if there is one and nothing is already in flight.
    func loadNext() async {
        guard let loadPage, !isLoading, hasMore else { return }
        let first = novels.isEmpty
        if first { isLoading = true } else { isLoadingMore = true }
        defer {
            isLoading = false
            isLoadingMore = false
        }

        let next = loadedPages + 1
        do {
            let page = try await loadPage(next)
            // Keep only ids not already shown: the sources overlap pages at their edges.
            let fresh = page.novels.filter { seen.insert($0.id).inserted }
            novels.append(contentsOf: fresh)
            loadedPages = next
            if let total = page.totalPages { totalPages = total }
            error = nil
        } catch {
            // A failure on a later page keeps what is already on screen; only an empty
            // list turns into an error state.
            if novels.isEmpty { self.error = error }
        }
    }

    /// Called by the last-but-one row. Matches Android's proximity trigger.
    func loadMoreIfNeeded(currentIndex: Int) {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        // Two rows of runway, so the next page is usually already there when reached.
        guard currentIndex >= novels.count - 2 else { return }
        Task { await loadNext() }
    }
}

/// Grid of novels backed by `PagedNovelListModel`.
struct PagedNovelGrid: View {
    @ObservedObject var model: PagedNovelListModel
    var open: (Int) -> Void

    // Same adaptive sizing as `NovelGrid`, so a paged list looks identical to a static one.
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(model.novels.enumerated()), id: \.element.id) { index, novel in
                Button {
                    open(novel.id)
                } label: {
                    NovelGridCell(novel: novel)
                }
                .buttonStyle(.plain)
                .onAppear { model.loadMoreIfNeeded(currentIndex: index) }
            }
        }
        .overlay(alignment: .bottom) {
            if let text = model.progressText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassCard(cornerRadius: 14)
                .padding(.bottom, 8)
            }
        }
    }
}

/// Row list backed by `PagedNovelListModel`, for screens that present books as rows.
struct PagedNovelList: View {
    @ObservedObject var model: PagedNovelListModel
    var open: (Int) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(model.novels.enumerated()), id: \.element.id) { index, novel in
                Button {
                    open(novel.id)
                } label: {
                    NovelRow(novel: novel)
                }
                .buttonStyle(.plain)
                .onAppear { model.loadMoreIfNeeded(currentIndex: index) }
                if index < model.novels.count - 1 {
                    Divider().padding(.leading, 76)
                }
            }
            if let text = model.progressText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }
}
