import SwiftUI
import Wenku8Core

/// Every tag the site publishes, as a starting point for browsing.
///
/// The website's book page carries no tags — they live on its tag pages — so this cloud is
/// the only way in for someone reading through the website. With the relay alone there is
/// nothing to show, and the screen says so instead of appearing empty.
struct TagCloudView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var tags: [String] = []
    @State private var isLoading = false
    @State private var error: Error?

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        ScrollView {
            if isLoading && tags.isEmpty {
                LoadingRow(text: "正在载入标签…")
            } else if let error, tags.isEmpty {
                ErrorStateView(error: error) {
                    Task { await load() }
                }
            } else if tags.isEmpty {
                EmptyStateView(
                    symbol: "number",
                    title: "暂时没有标签",
                    message: "站点没有返回标签列表。"
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            router.open(.tag(tag))
                        } label: {
                            TagChip(text: tag, systemImage: "number")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .background { AppBackground() }
        .navigationTitle("标签")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await Task { await load(force: true) }.value }
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        defer { isLoading = false }
        do {
            tags = try await NovelService().tagCloud()
            error = nil
        } catch {
            if tags.isEmpty { self.error = error }
        }
    }
}
