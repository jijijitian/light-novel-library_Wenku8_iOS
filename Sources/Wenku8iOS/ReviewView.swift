import SwiftUI
import Wenku8Core

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published private(set) var reviews: [NovelReview] = []
    @Published private(set) var isLoading = false
    /// True while a further page is on its way, as opposed to the first load.
    @Published private(set) var isLoadingPage = false
    @Published private(set) var error: Error?
    /// Whether the site has more pages than the ones already shown.
    @Published private(set) var hasMore = false

    private let service: NovelService
    private var novelID: Int?
    private var page = 0
    private var totalPages = 0
    private var loaded = false
    /// Identifies the current load, so a superseded one cannot write over its result.
    private var generation = 0

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(novelID: Int, force: Bool = false) async {
        // A pull used to be dropped while a load was in flight, so the gesture did
        // nothing exactly when the reader was most likely to try it.
        if isLoading && !force { return }
        guard force || !loaded else { return }

        generation &+= 1
        let mine = generation
        self.novelID = novelID
        isLoading = true
        defer { if generation == mine { isLoading = false } }
        do {
            let result = try await service.reviews(aid: novelID, page: 1, force: force)
            guard generation == mine else { return }
            reviews = result.reviews
            // A stored list may already cover several pages, and it knows which one it
            // reached — starting again from one would re-fetch what is already here.
            page = result.page
            totalPages = result.totalPages
            hasMore = result.page < result.totalPages
            error = nil
            loaded = true

            // A stored page carries the page count it was written with, which an older
            // manifest does not have. Refresh behind the list so the count — and the rows —
            // become current without making the reader wait.
            // Only a one-page cache is refreshed behind the list: a deeper one already holds
            // everything read so far, and replacing its first page would drop the rest.
            if result.isCached, result.page == 1 {
                Task { await self.revalidate(novelID: novelID, generation: mine) }
            }
        } catch {
            // Keep whatever is on screen; only an empty page becomes an error.
            if generation == mine, reviews.isEmpty { self.error = error }
        }
    }

    /// Refreshes the first page behind what is already on screen.
    private func revalidate(novelID: Int, generation mine: Int) async {
        guard let fresh = try? await service.reviews(aid: novelID, page: 1, force: true),
              generation == mine,
              // The reader may already have paged further; replacing the list then would
              // throw that away.
              page == 1 else { return }
        reviews = fresh.reviews
        totalPages = fresh.totalPages
        hasMore = fresh.totalPages > 1
    }

    /// Appends the next page. Called when the last row comes into view.
    func loadNextPage() async {
        guard hasMore, !isLoading, !isLoadingPage, let novelID, page > 0 else { return }
        let mine = generation
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            let result = try await service.reviews(aid: novelID, page: page + 1)
            guard generation == mine else { return }
            // The site sometimes repeats a row across pages; a duplicate id would be a
            // fatal error for `ForEach`, so only new ones are appended.
            let known = Set(reviews.map(\.id))
            reviews.append(contentsOf: result.reviews.filter { !known.contains($0.id) })
            page = result.page
            totalPages = result.totalPages
            hasMore = page < totalPages
            error = nil
        } catch {
            // A failed page keeps the rows already shown; the footer offers a retry.
            hasMore = false
        }
    }
}

struct ReviewListView: View {
    var novelID: Int
    @StateObject private var model = ReviewViewModel()
    @State private var selected: NovelReview?
    /// The book's cover colours, shared with the detail page so the two screens match.
    @AppStorage(CoverPalette.storageKey) private var coverTint = false
    @State private var palette: CoverPalette?

    var body: some View {
        ScrollView {
            if model.isLoading && model.reviews.isEmpty {
                LoadingRow(text: "正在载入书评…")
            } else if let error = model.error, model.reviews.isEmpty {
                ErrorStateView(error: error) {
                    Task { await model.load(novelID: novelID, force: true) }
                }
            } else if model.reviews.isEmpty {
                EmptyStateView(
                    symbol: "text.bubble",
                    title: "还没有书评",
                    message: "这本书暂时没有书评，去网页版发表第一条吧。"
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.reviews) { review in
                        Button {
                            selected = review
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "text.bubble.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(review.topic)
                                        .font(.subheadline.weight(.medium))
                                        .multilineTextAlignment(.leading)
                                    HStack(spacing: 8) {
                                        Text(review.author)
                                        Text(review.date)
                                        Text("\(review.replyCount) 回复")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // The last row coming into view is the signal to fetch the next
                            // page; with ten rows a page this only fires at the bottom.
                            if review.id == model.reviews.last?.id {
                                Task { await model.loadNextPage() }
                            }
                        }
                    }

                    if model.isLoadingPage {
                        LoadingRow(text: "正在载入更多书评…")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .background { TintedBackground(palette: coverTint ? palette : nil) }
        .navigationTitle("书评")
        .navigationBarTitleDisplayMode(.inline)
        // Unstructured, so the retracting refresh control cannot cancel the fetch.
        .refreshable { await Task { await model.load(novelID: novelID, force: true) }.value }
        .task {
            await loadPalette()
            await model.load(novelID: novelID)
        }
        .sheet(item: $selected) { review in
            ReviewDetailSheet(review: review, palette: coverTint ? palette : nil)
        }
    }

    /// Reads the cover's colours from the stored image; the book is usually already cached
    /// because the list is reached from the detail page.
    private func loadPalette() async {
        guard coverTint else {
            palette = nil
            return
        }
        let remote = await OfflineStore.shared.entry(for: novelID)?.detail?.coverURL
        palette = await CoverPalette.palette(for: novelID, remoteURL: remote)
    }
}

@MainActor
final class ReviewDetailViewModel: ObservableObject {
    @Published private(set) var posts: [ReviewPost] = []
    @Published private(set) var topic = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var error: Error?
    @Published private(set) var hasMore = false

    private let service: NovelService
    private var rid: Int?
    private var page = 0
    private var totalPages = 0

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(rid: Int) async {
        guard !isLoading else { return }
        self.rid = rid
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.reviewPosts(rid: rid, page: 1)
            posts = result.posts
            topic = result.topic
            page = 1
            totalPages = result.totalPages
            hasMore = result.totalPages > 1
            error = nil
        } catch {
            self.error = error
        }
    }

    /// Appends the next page of floors.
    func loadNextPage() async {
        guard hasMore, !isLoading, !isLoadingPage, let rid, page > 0 else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            let result = try await service.reviewPosts(rid: rid, page: page + 1)
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: result.posts.filter { !known.contains($0.id) })
            page = result.page
            totalPages = result.totalPages
            hasMore = page < totalPages
        } catch {
            hasMore = false
        }
    }
}

struct ReviewDetailSheet: View {
    var review: NovelReview
    var palette: CoverPalette?
    @StateObject private var model = ReviewDetailViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(review.topic)
                        .font(.headline)
                    if model.isLoading && model.posts.isEmpty {
                        LoadingRow()
                    } else if let error = model.error, model.posts.isEmpty {
                        ErrorStateView(error: error) {
                            Task { await model.load(rid: review.id) }
                        }
                    } else {
                        ForEach(model.posts) { post in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(post.author).font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(post.date).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(post.body)
                                    .font(.subheadline)
                                    .lineSpacing(4)
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 18)
                            .onAppear {
                                if post.id == model.posts.last?.id {
                                    Task { await model.loadNextPage() }
                                }
                            }
                        }

                        if model.isLoadingPage {
                            LoadingRow(text: "正在载入更多回复…")
                        }
                    }
                }
                .padding(18)
            }
            .background { TintedBackground(palette: palette) }
            .navigationTitle("书评详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await model.load(rid: review.id) }
        }
    }
}
