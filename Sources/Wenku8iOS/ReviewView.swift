import SwiftUI
import Wenku8Core

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published private(set) var reviews: [NovelReview] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private let service: NovelService
    private var loaded = false
    /// Identifies the current load, so a superseded one cannot write over its result.
    private var generation = 0

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(novelID: Int, force: Bool = false) async {
        guard force || !loaded else { return }
        // A pull used to be dropped while a load was in flight, so the gesture did
        // nothing exactly when the reader was most likely to try it.
        if isLoading && !force { return }
        generation &+= 1
        let mine = generation
        isLoading = true
        defer { if generation == mine { isLoading = false } }
        do {
            let result = try await service.reviews(aid: novelID)
            if generation == mine {
                reviews = result
                error = nil
                loaded = true
            }
        } catch {
            // Keep whatever is on screen; only an empty page becomes an error.
            if generation == mine, reviews.isEmpty { self.error = error }
        }
    }
}

struct ReviewListView: View {
    var novelID: Int
    @StateObject private var model = ReviewViewModel()
    @State private var selected: NovelReview?

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
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .background { AppBackground() }
        .navigationTitle("书评")
        .navigationBarTitleDisplayMode(.inline)
        // Unstructured, so the retracting refresh control cannot cancel the fetch.
        .refreshable { await Task { await model.load(novelID: novelID, force: true) }.value }
        .task { await model.load(novelID: novelID) }
        .sheet(item: $selected) { review in
            ReviewDetailSheet(review: review)
        }
    }
}

@MainActor
final class ReviewDetailViewModel: ObservableObject {
    @Published private(set) var posts: [ReviewPost] = []
    @Published private(set) var topic = ""
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private let service: NovelService

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(rid: Int) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.reviewPosts(rid: rid)
            posts = result.posts
            topic = result.topic
            error = nil
        } catch {
            self.error = error
        }
    }
}

struct ReviewDetailSheet: View {
    var review: NovelReview
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
                        }
                    }
                }
                .padding(18)
            }
            .background { AppBackground() }
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
