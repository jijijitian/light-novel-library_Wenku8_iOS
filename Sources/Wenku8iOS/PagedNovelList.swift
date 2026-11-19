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
    /// Loads in flight; a second request for a page already being fetched is dropped.
    private var inFlight = 0
    /// Identifies the current load, so a superseded one cannot write over its result.
    private var generation = 0

    /// Minimum time the refresh indicator stays up, matching the other screens.
    private static let minimumRefreshDuration: Duration = .milliseconds(1000)

    /// Rows per screen is twelve, so the first fetch takes two pages and later fetches
    /// take one. That puts a full screen plus its successor in hand before the reader
    /// can scroll, rather than filling in after they arrive at the bottom.
    private let initialPages = 2

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

    /// Number of placeholder cells to draw below the loaded books.
    ///
    /// One page of placeholders while more exists: the reader sees the shape of the next
    /// rows immediately and they fill in as the data arrives, instead of the list ending
    /// at the screen edge and growing only after a scroll.
    var placeholderCount: Int {
        guard hasMore, loadPage != nil else { return 0 }
        // Complete the row the last book is on, then add two rows. The old arithmetic
        // assumed a page of twelve with three per row, which no source actually uses — the
        // relay returns ten — so the fill never lined up with the grid.
        let columns = 3
        let remainder = novels.count % columns
        let toFillRow = remainder == 0 ? 0 : columns - remainder
        return toFillRow + columns * 2
    }

    /// Prepares the list for a source, loading it only when it is not on screen yet.
    ///
    /// Returning to a screen that already has its data must not clear and refetch it: that
    /// is what made every visit look like a reload.
    func start(_ loader: @escaping (Int) async throws -> NovelListPage) async {
        loadPage = loader
        guard novels.isEmpty else { return }
        await reload()
    }

    /// Re-fetches from the first page, replacing the list only once new data arrives.
    ///
    /// The old version cleared `novels` before fetching, so a pull emptied the screen and
    /// a failed refresh left it empty. Nothing is cleared now: the pages are collected
    /// aside and swapped in on success.
    func reload() async {
        // `.refreshable` cancels its closure when the control retracts; the pages are
        // fetched in an unstructured task so a cancelled runner cannot abort them.
        let work = Task { await self.performReload() }
        await work.value
    }

    private func performReload() async {
        guard let loadPage else { return }
        // A refresh supersedes whatever is in flight rather than being dropped by it.
        generation &+= 1
        let mine = generation
        isLoading = novels.isEmpty
        // Hold the prefetch off while the list is being replaced: a page appended by a
        // scroll during a refresh would be overwritten by the result anyway.
        inFlight += 1
        // No "正在载入列表 2/426" here: the system indicator is already spinning, and a
        // page counter during a refresh describes work the reader did not ask to track.
        defer {
            inFlight -= 1
            if generation == mine { isLoading = false }
        }

        let started = ContinuousClock.now
        var fresh: [NovelSummary] = []
        var freshSeen = Set<Int>()
        var pages = 0
        var total: Int?
        var failure: Error?

        for _ in 0..<initialPages {
            if generation != mine { return }
            if let total, pages >= total { break }
            do {
                let page = try await loadPage(pages + 1)
                fresh.append(contentsOf: page.novels.filter { freshSeen.insert($0.id).inserted })
                pages += 1
                if let reported = page.totalPages { total = reported }
            } catch {
                failure = error
                break
            }
        }

        guard generation == mine else { return }
        if pages > 0 {
            novels = fresh
            seen = freshSeen
            loadedPages = pages
            totalPages = total
            error = nil
        } else if novels.isEmpty {
            // Only an empty screen becomes an error; a refresh that failed keeps what the
            // reader was already reading.
            self.error = failure
        }

        // Floor the indicator like the other screens, so a warm refresh is visible.
        let deadline = started + Self.minimumRefreshDuration
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Loads one more page, if there is one and nothing is already in flight.
    func loadNext() async {
        guard loadPage != nil, hasMore else { return }
        await fetchNextPage(reporting: true)
    }

    private func fetchNextPage(reporting: Bool) async {
        guard let loadPage, hasMore else { return }
        if reporting { isLoadingMore = true }
        inFlight += 1
        defer {
            inFlight -= 1
            isLoadingMore = false
            isLoading = false
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

    /// Called by each rendered cell. Kept for the paged grids, but placeholders are what
    /// actually drive the prefetch now, so reaching the end is no longer required.
    func loadMoreIfNeeded(currentIndex: Int) {
        guard hasMore, !isLoadingMore, inFlight == 0 else { return }
        guard currentIndex >= novels.count - 3 else { return }
        Task { await loadNext() }
    }

    /// Called when a placeholder comes into view: fetches the next page before the reader
    /// reaches the edge of what is loaded.
    func ensurePlaceholderTriggered() {
        guard hasMore, inFlight == 0 else { return }
        Task { await loadNext() }
    }
}

/// Grid of novels backed by `PagedNovelListModel`.
struct PagedNovelGrid: View {
    @ObservedObject var model: PagedNovelListModel
    var open: (Int) -> Void

    // Same adaptive sizing as `NovelGrid`, so a paged list looks identical to a static one.
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 14)]

    /// One grid child, in one identity space.
    ///
    /// The grid used to hold two sibling `ForEach`es — novels keyed by book id, placeholders
    /// keyed by their index. As pages arrived the placeholder range shrank while books were
    /// inserted where those placeholders had been, and a recycled placeholder could be left
    /// behind in the middle of loaded rows: a skeleton sitting between two real books, in a
    /// grid where placeholders only ever belong at the end. A single list with a single set
    /// of ids removes the ambiguity.
    private enum Cell: Identifiable {
        case novel(NovelSummary, index: Int)
        case placeholder(Int)
        case loading(Int)

        var id: String {
            switch self {
            case .novel(let novel, _): return "novel-\(novel.id)"
            case .placeholder(let index): return "placeholder-\(index)"
            case .loading(let index): return "loading-\(index)"
            }
        }
    }

    private var cells: [Cell] {
        if model.novels.isEmpty && model.isLoading {
            return (0..<12).map { .loading($0) }
        }
        var result = model.novels.enumerated().map { Cell.novel($1, index: $0) }
        result += (0..<model.placeholderCount).map { .placeholder($0) }
        return result
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(cells) { cell in
                switch cell {
                case .novel(let novel, let index):
                    Button {
                        open(novel.id)
                    } label: {
                        NovelGridCell(novel: novel)
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.loadMoreIfNeeded(currentIndex: index) }
                case .placeholder:
                    // Placeholder covers occupy the next rows from the start, so the list
                    // has the shape of its continuation instead of ending at the data.
                    PlaceholderGridCell()
                        .onAppear { model.ensurePlaceholderTriggered() }
                case .loading:
                    PlaceholderGridCell()
                }
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
            if model.novels.isEmpty && model.isLoading {
                ForEach(0..<12, id: \.self) { _ in PlaceholderRow() }
            }
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
            ForEach(0..<model.placeholderCount, id: \.self) { _ in
                PlaceholderRow()
                    .onAppear { model.ensurePlaceholderTriggered() }
            }
        }
    }
}

/// A cover-shaped placeholder, drawn before the book it will become.
///
/// Sized from the same width as `NovelGridCell` so the grid does not reflow when the
/// real covers arrive.
struct PlaceholderGridCell: View {
    /// Matches `NovelGridCell`'s default cover size, not the column width.
    ///
    /// The real cell draws a fixed 96×136 cover inside a column that can be up to 130
    /// wide; sizing the placeholder by the column made it a size larger than the cover
    /// it stood in for, so the grid visibly shrank as pages arrived.
    var width: CGFloat = 96

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(width: width, height: width * 1.42)
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: width, height: 10)
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.6))
                .frame(width: 48, height: 10)
            // Holds the second title line's space so the cell is the same height as a
            // real one with a two-line title.
            Spacer(minLength: 0)
                .frame(height: 10)
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

/// A row-shaped placeholder, for lists that present books as rows.
struct PlaceholderRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 64, height: 90)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.7))
                    .frame(width: 96, height: 10)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.5))
                    .frame(width: 64, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}
