import SwiftUI
import Wenku8Core

/// One ordering of a tag's books.
///
/// The website is the only source that can list books by tag — the relay publishes a book's
/// tags but has no way to filter by one — so this screen is reachable only when the website
/// is in use.
struct TagBooksView: View {
    var tag: String
    var sort: TagSort

    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = PagedNovelListModel()
    /// The last list read for this tag and ordering, painted while the refresh is in flight.
    @State private var stored: [NovelSummary] = []

    var body: some View {
        ScrollView {
            if model.novels.isEmpty && model.isLoading {
                if stored.isEmpty {
                    LoadingRow(text: "正在载入「\(tag)」的书…")
                } else {
                    NovelGrid(novels: stored) { novel in
                        router.open(.novel(novel.id))
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task {
            if stored.isEmpty { restore() }
            await reload()
        }
        .onChange(of: model.novels.count) { _, _ in store() }
    }

    private var title: String {
        sort == .updated ? tag : "\(tag) · \(sort.shortTitle)"
    }

    // MARK: - Stored list

    /// Tag lists change slowly and reading one costs a login-gated page load, so the last
    /// result is kept per tag and ordering.
    private struct StoredList: Codable {
        var savedAt: Date
        var novels: [NovelSummary]
    }

    private static var cacheDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TagLists", isDirectory: true)
    }

    private var cacheURL: URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (tag + "#" + sort.rawValue).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Self.cacheDirectory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    private func restore() {
        guard let data = try? Data(contentsOf: cacheURL),
              let list = try? JSONDecoder().decode(StoredList.self, from: data) else { return }
        stored = list.novels
    }

    private func store() {
        guard !model.novels.isEmpty else { return }
        let list = StoredList(savedAt: Date(), novels: Array(model.novels.prefix(24)))
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(
            at: Self.cacheDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func reload() async {
        await model.restart { page in
            try await NovelService().novels(tag: tag, page: page, sort: sort)
        }
    }
}
