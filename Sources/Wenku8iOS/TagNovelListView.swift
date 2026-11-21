import SwiftUI
import Wenku8Core

/// A tag's book list.
///
/// The website is the only source that can list books by tag — the relay publishes a book's
/// tags but has no way to filter by one — so this screen is reachable only when the website
/// is in use. The detail page explains that when it is not, rather than opening an empty
/// list.
struct TagNovelListView: View {
    var tag: String

    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = PagedNovelListModel()

    var body: some View {
        ScrollView {
            if model.novels.isEmpty && model.isLoading {
                LoadingRow(text: "正在载入「\(tag)」的书…")
            } else if let error = model.error, model.novels.isEmpty {
                ErrorStateView(error: error) {
                    Task { await reload() }
                }
            } else if model.novels.isEmpty {
                EmptyStateView(
                    symbol: "number",
                    title: "这个标签下没有书",
                    message: "站点的标签书单是空的。"
                )
            } else {
                PagedNovelGrid(model: model) { novelID in
                    router.open(.novel(novelID))
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
        }
        .background { AppBackground() }
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task { await reload() }
    }

    private func reload() async {
        await model.start { page in
            try await NovelService().novels(tag: tag, page: page)
        }
    }
}
