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
    /// The book awaiting confirmation, by id and title.
    ///
    /// Holding the whole `Entry` meant arming the alert handed every row a new value to compare
    /// against — the record carries the book's detail and its whole catalogue — and the open row
    /// was re-measured, which is what made the list jump.
    @State private var pendingDeleteBookID: Int?
    @State private var pendingDeleteBookTitle: String?
    @State private var pendingDeleteVolume: PendingVolume?
    /// Cover files stored on this device, keyed by book.
    @State private var localCovers: [Int: URL] = [:]

    /// Whether the list is being picked from rather than read.
    @State private var isSelecting = false
    /// Picked volumes, keyed "book:volume" so one volume of one book is one entry.
    @State private var pickedVolumes: Set<String> = []
    /// Confirming a multi-delete.
    @State private var confirmingMultiDelete = false

    /// A volume queued for deletion, with the book it belongs to.
    struct PendingVolume: Identifiable {
        let id = UUID()
        var novelID: Int
        var title: String
        var chapterIDs: Set<Int>
    }

    var body: some View {
        // The alert sits on a container that does not scroll.
        //
        // Attached to the `List`, arming the delete made the list adjust its own layout while
        // the alert appeared — nothing was rebuilt (the row logs confirm it), but its offset
        // shifted for a moment, which reads as the list jumping up a row and back.
        ZStack {
            listContent
        }
        .navigationTitle(isSelecting ? "已选 \(pickedVolumes.count) 卷" : "离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("完成") {
                        isSelecting = false
                        pickedVolumes.removeAll()
                    }
                } else {
                    Menu {
                        Button {
                            isSelecting = true
                            pickedVolumes.removeAll()
                        } label: {
                            Label("选择", systemImage: "checkmark.circle")
                        }
                        .disabled(entries.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .alert("删除选中的 \(pickedVolumes.count) 卷？", isPresented: $confirmingMultiDelete) {
            Button("删除", role: .destructive) { deletePicked() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除选中分卷已下载的章节，书籍元数据保留。")
        }
        .task { await refresh() }
        .onChange(of: manager.progress) { _, newValue in
            // Keep in step as each chapter lands, so a finished volume updates immediately
            // instead of waiting for the whole book.
            Task { await refresh() }
            if newValue == nil { Task { await refresh() } }
        }
        .alert("删除整本书？", isPresented: bookDeleteBinding) {
            Button("删除", role: .destructive) { deleteBook() }
            Button("取消", role: .cancel) {
                pendingDeleteBookID = nil
                pendingDeleteBookTitle = nil
            }
        } message: {
            Text(pendingDeleteBookTitle ?? "")
        }
        .alert("删除这个分卷？", isPresented: volumeDeleteBinding) {
            Button("删除", role: .destructive) { deleteVolume() }
            Button("取消", role: .cancel) { pendingDeleteVolume = nil }
        } message: {
            Text(volumeDeleteMessage)
        }
    }

    private var bookDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDeleteBookID != nil }, set: { if !$0 { pendingDeleteBookID = nil } })
    }

    private var volumeDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDeleteVolume != nil }, set: { if !$0 { pendingDeleteVolume = nil } })
    }

    private var volumeDeleteMessage: String {
        let title = pendingDeleteVolume?.title ?? ""
        return "只会删除「\(title)」已下载的章节，书籍元数据和其它分卷保留。"
    }

    private func deleteBook() {
        guard let id = pendingDeleteBookID else { return }
        pendingDeleteBookID = nil
        pendingDeleteBookTitle = nil
        // The row leaves in this one update; deleting first made the list animate once when
        // the alert closed and again when the reload landed.
        entries.removeAll { $0.novelID == id }
        Task {
            await manager.delete(id)
            await refresh()
        }
    }

    /// The bar under the list while picking.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(pickedVolumes.count) 卷")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Button {
                confirmingMultiDelete = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(pickedVolumes.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Deletes the stored chapters of every picked volume.
    private func deletePicked() {
        let picks = pickedVolumes
        pickedVolumes.removeAll()
        isSelecting = false
        Task {
            for pick in picks {
                let parts = pick.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let aid = Int(parts[0]) else { continue }
                let volumeID = String(parts[1])
                guard let entry = entries.first(where: { $0.novelID == aid }),
                      let volume = entry.volumes?.first(where: { $0.id == volumeID })
                else { continue }
                let held = Set(volume.chapters.map(\.id)).intersection(entry.storedChapterIDs)
                _ = await OfflineStore.shared.deleteChapters(held, for: aid)
            }
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
    ///
    /// Its own view so the disclosure's expanded state belongs to the row. As a function
    /// returning rows, the row was rebuilt on every pass over the list and the disclosure
    /// collapsed for a moment whenever an alert appeared — the rows below jumped up and back.
    private func bookRow(_ entry: OfflineStore.Entry) -> some View {
        StoredBookRow(
            entry: entry,
            live: manager.progress.flatMap { $0.novelID == entry.novelID ? $0 : nil },
            stored: storedVolumes(entry),
            coverURL: coverURL(for: entry),
            header: { live in
                AnyView(bookHeader(entry, live: live))
            },
            volumeRow: { volume in
                AnyView(volumeRow(entry: entry, volume: volume))
            },
            onOpen: { router.open(.novel(entry.novelID)) },
            onDeleteVolume: { volume in
                let held = volume.chapters.filter { entry.storedChapterIDs.contains($0.id) }
                pendingDeleteVolume = PendingVolume(
                    novelID: entry.novelID,
                    title: volume.title,
                    chapterIDs: Set(held.map(\.id))
                )
            },
            isSelecting: isSelecting,
            picked: pickedVolumes,
            onPickBook: {
                // Picking the book takes all of its stored volumes, or clears them when they
                // are all picked already.
                let keys = storedVolumes(entry).map { "\(entry.novelID):\($0.id)" }
                if keys.allSatisfy({ pickedVolumes.contains($0) }) {
                    pickedVolumes.subtract(keys)
                } else {
                    pickedVolumes.formUnion(keys)
                }
            },
            onPickVolume: { volume in
                let key = "\(entry.novelID):\(volume.id)"
                if pickedVolumes.contains(key) {
                    pickedVolumes.remove(key)
                } else {
                    pickedVolumes.insert(key)
                }
            }
        )
    }

    /// Cover, title and the book's overall state.
    ///
    /// Reached through `StoredBookRow`, which owns the disclosure state.
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
                        // Inside a button the title would take the accent colour.
                        .foregroundStyle(.primary)
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
        }
        .padding(.vertical, 4)
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

    /// The list itself, kept apart so the alert is not attached to it.
    ///
    /// A `List` draws its rows on the system's background, which the rest of the app hides; the
    /// rows then read as holes rather than as the glass panels every other screen uses.
    @ViewBuilder
    private var listContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                if entries.isEmpty {
                    EmptyStateView(
                        symbol: "arrow.down.circle",
                        title: "还没有下载的小说",
                        message: "在小说详情页的目录里选择要下载的分卷，即可离线阅读。"
                    )
                    .padding(.top, 40)
                } else {
                    Panel {
                        ForEach(entries) { entry in
                            bookRow(entry)
                                // A long press rather than a swipe.
                                //
                                // Swiping draws the row aside and back, and the list re-measures
                                // during that animation — with a row expanded, everything below it
                                // visibly jumped. The context menu changes nothing about the row's
                                // layout, so the delete can be armed without any movement.
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDeleteBookID = entry.novelID
                                        pendingDeleteBookTitle = entry.title
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            if entry.id != entries.last?.id {
                                Divider()
                            }
                        }
                    }

                    Text("共 \(entries.count) 本 · \(formatBytes(totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
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

/// One stored book, with its volumes behind a disclosure.
struct StoredBookRow: View {
    let entry: OfflineStore.Entry
    let live: OfflineDownloadManager.Progress?
    let stored: [Volume]
    let coverURL: URL?
    /// Builds the header; takes the live progress so the row can show a running download.
    let header: (OfflineDownloadManager.Progress?) -> AnyView
    /// Builds one volume's row.
    let volumeRow: (Volume) -> AnyView

    var onOpen: () -> Void
    var onDeleteVolume: (Volume) -> Void

    /// Picking mode: rows select instead of opening.
    var isSelecting: Bool = false
    /// Every picked volume, keyed `book:volume`.
    var picked: Set<String> = []
    var onPickBook: () -> Void = {}
    var onPickVolume: (Volume) -> Void = { _ in }

    /// Whether every stored volume of this book is picked.
    private var allPicked: Bool {
        !stored.isEmpty && stored.allSatisfy { picked.contains("\(entry.novelID):\($0.id)") }
    }

    private func isPicked(_ volume: Volume) -> Bool {
        picked.contains("\(entry.novelID):\(volume.id)")
    }

    /// Owned by the row, so a pass over the list cannot reset it.
    @State private var isExpanded = false

    /// The indent a disclosure adds to its content, cancelled so volume titles align with the
    /// book title rather than starting under the chevron.
    static let disclosureIndent: CGFloat = 18

    /// Room kept clear at the row's trailing edge for the disclosure's own chevron.
    static let chevronHitWidth: CGFloat = 36

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(stored) { volume in
                HStack(spacing: 8) {
                    // A volume is a choice of its own while picking, so it gets its own tick.
                    if isSelecting {
                        tick(isOn: isPicked(volume))
                    }
                    volumeRow(volume)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelecting { onPickVolume(volume) }
                }
                // A menu leaves the layout alone, which is why deleting does not move the rows
                // below it.
                .contextMenu {
                    if !isSelecting {
                        Button(role: .destructive) {
                            onDeleteVolume(volume)
                        } label: {
                            Label("删除本卷", systemImage: "trash")
                        }
                    }
                }
            }
            // A disclosure indents its content to line up under the label's chevron, which put
            // the volume titles well to the right of the book title above them. Pulling the
            // block back by that indent lines the two up.
            .padding(.leading, -Self.disclosureIndent)
        } label: {
            HStack(spacing: 8) {
                // Picking the book takes every stored volume it has; picking all of them by
                // hand fills this in — the same rule in both directions.
                if isSelecting {
                    tick(isOn: allPicked)
                }
                header(live)
                    // The cache rows share one height with the metadata list, so the two read as
                    // the same kind of thing.
                    .frame(minHeight: PanelMetrics.coverRowHeight, alignment: .leading)
            }
            // Wide, but short of the trailing edge: the disclosure draws its chevron there, and
            // a label reaching it swallowed the tap — the arrow opened the book instead of the
            // volume list.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, Self.chevronHitWidth)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting { onPickBook() } else { onOpen() }
            }
            // The row sits inside a link's label, and a link tints everything it contains.
            .tint(.primary)
        }
        // The chevron is drawn beside the label, so the inset goes on the control as a whole.
        .padding(.horizontal, 16)
    }

    /// A tick in a fixed-width box, so rows do not shift as the label changes.
    private func tick(isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.body)
            .foregroundStyle(isOn ? AppTheme.accent : Color.secondary)
            .frame(width: 22)
    }
}
