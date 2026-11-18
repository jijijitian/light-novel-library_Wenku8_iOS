import SwiftUI
import Wenku8Core

/// Lists downloaded books, expanding into the volumes actually held on disk.
///
/// A download can cover only some volumes, so the interesting unit is the volume: the book
/// row summarises, and expanding shows which volumes are stored and lets each be removed on
/// its own. Deleting a volume frees its space without discarding the book.
struct OfflineLibraryView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var manager = OfflineDownloadManager.shared
    @State private var entries: [OfflineStore.Entry] = []
    @State private var totalBytes: Int64 = 0
    @State private var expanded: Set<Int> = []
    @State private var pendingDeleteBook: OfflineStore.Entry?
    @State private var pendingDeleteVolume: PendingVolume?
    /// Cover files stored on this device, keyed by book.
    @State private var localCovers: [Int: URL] = [:]

    /// A volume queued for deletion, with the book it belongs to.
    struct PendingVolume: Identifiable {
        let id = UUID()
        var novelID: Int
        var title: String
        var chapterIDs: Set<Int>
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: "arrow.down.circle",
                        title: "还没有下载的小说",
                        message: "在小说详情页的目录里选择要下载的分卷，即可离线阅读。"
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        bookRow(entry)
                    }
                    .onDelete { offsets in
                        if let index = offsets.first { pendingDeleteBook = entries[index] }
                    }
                } footer: {
                    Text("共 \(entries.count) 本 · \(formatBytes(totalBytes))")
                }
            }
        }
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: manager.progress) { _, newValue in
            // Keep in step as each chapter lands, so a finished volume updates immediately
            // instead of waiting for the whole book.
            Task { await refresh() }
            if newValue == nil { Task { await refresh() } }
        }
        .alert("删除整本书？", isPresented: bookDeleteBinding) {
            Button("删除", role: .destructive) { deleteBook() }
            Button("取消", role: .cancel) { pendingDeleteBook = nil }
        } message: {
            Text(pendingDeleteBook?.title ?? "")
        }
        .alert("删除这个分卷？", isPresented: volumeDeleteBinding) {
            Button("删除", role: .destructive) { deleteVolume() }
            Button("取消", role: .cancel) { pendingDeleteVolume = nil }
        } message: {
            Text(volumeDeleteMessage)
        }
    }

    private var bookDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDeleteBook != nil }, set: { if !$0 { pendingDeleteBook = nil } })
    }

    private var volumeDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDeleteVolume != nil }, set: { if !$0 { pendingDeleteVolume = nil } })
    }

    private var volumeDeleteMessage: String {
        let title = pendingDeleteVolume?.title ?? ""
        return "只会删除「\(title)」已下载的章节，书籍元数据和其它分卷保留。"
    }

    private func deleteBook() {
        guard let entry = pendingDeleteBook else { return }
        pendingDeleteBook = nil
        Task {
            await manager.delete(entry.novelID)
            await refresh()
        }
    }

    private func deleteVolume() {
        guard let volume = pendingDeleteVolume else { return }
        pendingDeleteVolume = nil
        Task {
            await OfflineStore.shared.deleteChapters(volume.chapterIDs, for: volume.novelID)
            await refresh()
        }
    }

    /// The cached cover file for a book, or its remote URL as a last resort.
    ///
    /// Reading the stored file keeps this screen offline-correct; the remote URL is only
    /// used for a book downloaded before covers were saved.
    private func coverURL(for entry: OfflineStore.Entry) -> URL? {
        localCovers[entry.novelID] ?? entry.detail?.coverURL
    }

    // MARK: - Rows

    /// A book, expandable into the volumes that are stored.
    @ViewBuilder
    private func bookRow(_ entry: OfflineStore.Entry) -> some View {
        let live = manager.progress.flatMap { $0.novelID == entry.novelID ? $0 : nil }
        let stored = storedVolumes(entry)
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(entry.novelID) },
            set: { isOpen in
                if isOpen { expanded.insert(entry.novelID) } else { expanded.remove(entry.novelID) }
            }
        )) {
            ForEach(stored) { volume in
                volumeRow(entry: entry, volume: volume)
            }
        } label: {
            bookHeader(entry, live: live)
        }
    }

    /// Cover, title and the book's overall state.
    private func bookHeader(_ entry: OfflineStore.Entry, live: OfflineDownloadManager.Progress?) -> some View {
        HStack(spacing: 12) {
            CoverCard(
                url: coverURL(for: entry),
                title: entry.title,
                width: 40,
                height: 56
            )
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    router.open(.novel(entry.novelID))
                } label: {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                if let author = entry.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(summary(entry, live: live))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            trailingControl(entry, live: live)
        }
        .padding(.vertical, 4)
    }

    /// Pause while downloading, resume when incomplete, a tick when everything is held.
    @ViewBuilder
    private func trailingControl(
        _ entry: OfflineStore.Entry,
        live: OfflineDownloadManager.Progress?
    ) -> some View {
        if live != nil || manager.startingNovelID == entry.novelID {
            // Also while the first request is in flight, so the tap registers at once.
            Button {
                manager.cancel()
                Task { await refresh() }
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("暂停下载")
        } else if !entry.isComplete {
            Button {
                manager.download(novelID: entry.novelID)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("继续下载")
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("已全部下载")
        }
    }

    /// One volume, with its own delete affordance.
    private func volumeRow(entry: OfflineStore.Entry, volume: Volume) -> some View {
        let held = volume.chapters.filter { entry.storedChapterIDs.contains($0.id) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.title)
                    .font(.footnote)
                    .lineLimit(2)
                Text("\(held.count)/\(volume.chapters.count) 章")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if held.count < volume.chapters.count {
                Button {
                    manager.download(
                        novelID: entry.novelID,
                        volumeIDs: [volume.id]
                    )
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("下载这一卷")
            }
            Button(role: .destructive) {
                pendingDeleteVolume = PendingVolume(
                    novelID: entry.novelID,
                    title: volume.title,
                    chapterIDs: Set(held.map(\.id))
                )
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(held.isEmpty ? Color.secondary : Color.red)
            }
            .buttonStyle(.borderless)
            .disabled(held.isEmpty)
            .accessibilityLabel("删除这一卷")
        }
        .padding(.leading, 52)
    }

    // MARK: - Data

    /// Volumes of this book that hold at least one stored chapter.
    private func storedVolumes(_ entry: OfflineStore.Entry) -> [Volume] {
        guard let volumes = entry.volumes else {
            // A manifest written before the catalogue was stored: fall back to one group
            // so the chapters are still reachable rather than hidden.
            guard !entry.storedChapterIDs.isEmpty else { return [] }
            let chapters = entry.chapterIDs
                .filter { entry.storedChapterIDs.contains($0) }
                .map { ChapterLink(id: $0, title: entry.chapterTitles[$0] ?? "第 \($0) 章") }
            return [Volume(id: "legacy", title: "已缓存章节", chapters: chapters)]
        }
        return volumes.filter { volume in
            volume.chapters.contains { entry.storedChapterIDs.contains($0.id) }
        }
    }

    /// The line under the title: what is held, and what the download is doing.
    private func summary(_ entry: OfflineStore.Entry, live: OfflineDownloadManager.Progress?) -> String {
        if let live {
            return "\(live.completed)/\(live.total) 章 · \(live.currentChapterTitle)"
        }
        if manager.startingNovelID == entry.novelID {
            return "准备中…"
        }
        let held = entry.storedChapterIDs.count
        let total = entry.chapterIDs.count
        let volumes = storedVolumes(entry).count
        var parts = ["\(held)/\(total) 章"]
        if volumes > 0 { parts.append("\(volumes) 卷") }
        parts.append(formatBytes(entry.bytes))
        return parts.joined(separator: " · ")
    }

    private func refresh() async {
        // Downloads only. A book that was opened once has cached metadata but no chapters,
        // and listing it here claimed a download that never happened.
        entries = await OfflineStore.shared.downloadedEntries()
        totalBytes = await OfflineStore.shared.totalBytes()
        var covers: [Int: URL] = [:]
        for entry in entries {
            if let url = await OfflineStore.shared.coverURL(for: entry.novelID) {
                covers[entry.novelID] = url
            }
        }
        localCovers = covers
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
