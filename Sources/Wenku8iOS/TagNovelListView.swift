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
    /// The last list read for this tag, painted while the refresh is in flight.
    @State private var stored: [NovelSummary] = []
    /// The site offers four orderings of a tag; this is the one on screen.
    @State private var sort: TagSort = .updated

    var body: some View {
        ScrollView {
            sortRow
                .padding(.horizontal, 18)
                .padding(.top, 8)

            if model.novels.isEmpty && model.isLoading {
                if stored.isEmpty {
                    LoadingRow(text: "正在载入「\(tag)」的书…")
                } else {
                    // The stored list stays on screen while the fresh one loads: a blank
                    // grid for a second reads as the tag having no books.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在刷新「\(tag)」的书…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        NovelGrid(novels: stored) { novel in
                            router.open(.novel(novel.id))
                        }
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
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task {
            if stored.isEmpty { restore() }
            await reload()
        }
        .onChange(of: model.novels.count) { _, _ in store() }
        .onChange(of: sort) { _, _ in
            // A different ordering is a different list, so the stored copy is swapped
            // before the request goes out.
            stored = []
            restore()
            Task { await reloadForSort() }
        }
    }

    // MARK: - Stored list

    /// Tag lists change slowly and reading one costs a login-gated page load, so the last
    /// result is kept per tag and shown while the fresh one is fetched.
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

    /// The four orderings the site links above a tag's list.
    private var sortRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TagSort.allCases) { option in
                    Button {
                        sort = option
                    } label: {
                        Text(option.title)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(sort == option ? Color.accentColor : .primary)
                            .glassCapsule(interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func reload() async {
        let sort = self.sort
        await model.start { page in
            try await NovelService().novels(tag: tag, page: page, sort: sort)
        }
    }

    /// Swaps the ordering under an already-loaded list.
    private func reloadForSort() async {
        await reload()
        await model.reload()
    }
}
