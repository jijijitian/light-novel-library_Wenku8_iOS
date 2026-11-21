import SwiftUI
import Wenku8Core

struct ExploreView: View {
    @EnvironmentObject private var router: AppRouter
    /// The website homepage's panels, shown above the boards.
    @State private var blocks: [DesktopParser.HomeBlock] = []
    @State private var isLoadingBlocks = false
    @State private var blocksError: Error?
    /// Panels the reader opened to see all their books instead of the first few.
    @State private var expandedBlocks: Set<String> = []
    @State private var savedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The two ways in, first thing on the page: everything below is the
                // website's own panels, which are for browsing rather than for finding a
                // specific screen.
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        router.open(.rankBoards)
                    } label: {
                        entryRow(
                            title: "排行榜",
                            subtitle: "年度榜单与 13 个分类排行",
                            symbol: "chart.bar"
                        )
                    }
                    .buttonStyle(.plain)

                    Divider().opacity(0.35)

                    Button {
                        router.open(.tagCloud)
                    } label: {
                        entryRow(
                            title: "Tags云集",
                            subtitle: "按题材浏览全站标签",
                            symbol: "number"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .glassCard(cornerRadius: 22)

                exploreBlocks

            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("探索")
        .task {
            // Paint what was stored first, then refresh: the panels are the first thing
            // the screen shows and should not arrive after the reader has looked at it.
            if blocks.isEmpty { restore() }
            await loadBlocks()
        }
        .refreshable { await Task { await loadBlocks(force: true) }.value }
    }

    // MARK: - Website homepage

    /// The website's own homepage panels.
    ///
    /// They need a session and they are website content, so relay-only mode says so in one
    /// short card instead of leaving a hole in the page.
    @ViewBuilder
    private var exploreBlocks: some View {
        if !blocks.isEmpty {
            ForEach(blocks) { block in
                let expanded = expandedBlocks.contains(block.id)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: block.title, symbol: "sparkles")
                        if let sort = block.moreSort, let board = RankBoard(rawValue: sort) {
                            Button {
                                router.open(.rankList(board))
                            } label: {
                                Text("更多")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                        if block.novels.count > 4 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expanded {
                                        expandedBlocks.remove(block.id)
                                    } else {
                                        expandedBlocks.insert(block.id)
                                    }
                                }
                            } label: {
                                Text(expanded ? "收起" : "展开全部")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if expanded {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                            alignment: .leading,
                            spacing: 14
                        ) {
                            ForEach(block.novels) { novel in
                                novelCell(novel)
                            }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(block.novels) { novel in
                                    novelCell(novel)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
            }
        } else if isLoadingBlocks {
            LoadingRow(text: "正在载入探索板块…")
        } else if let blocksError {
            VStack(alignment: .leading, spacing: 8) {
                Label("探索板块暂时无法载入", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
                Text((blocksError as? LocalizedError)?.errorDescription ?? "请稍后再试")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await loadBlocks(force: true) }
                } label: {
                    Label("重新载入", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .secondaryGlassButtonShape()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22)
        }
    }

    // MARK: - Stored panels

    /// The panels are worth keeping between launches: they are the same for hours, and the
    /// homepage is a session-gated page that can be slow.
    private struct ExploreSnapshot: Codable {
        var savedAt: Date
        var blocks: [DesktopParser.HomeBlock]
    }

    private static var snapshotURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ExploreSnapshot.json")
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(ExploreSnapshot.self, from: data) else {
            return
        }
        blocks = snapshot.blocks
        savedAt = snapshot.savedAt
    }

    private func store() {
        guard !blocks.isEmpty else { return }
        let snapshot = ExploreSnapshot(savedAt: Date(), blocks: blocks)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.snapshotURL, options: .atomic)
        savedAt = snapshot.savedAt
    }

    /// One book in a panel: cover plus title, the same in both layouts.
    private func novelCell(_ novel: NovelSummary) -> some View {
        Button {
            router.open(.novel(novel.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverCard(
                    url: novel.coverURL,
                    title: novel.title,
                    width: 88,
                    height: 124
                )
                Text(novel.title)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 88, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadBlocks(force: Bool = false) async {
        if isLoadingBlocks && !force { return }
        isLoadingBlocks = true
        defer { isLoadingBlocks = false }
        do {
            blocks = try await NovelService().exploreBlocks()
            blocksError = nil
            store()
        } catch {
            if blocks.isEmpty { blocksError = error }
        }
    }

    /// One row in the "去别处看看" card.
    private func entryRow(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
