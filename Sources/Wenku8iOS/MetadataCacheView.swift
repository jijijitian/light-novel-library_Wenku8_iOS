import SwiftUI
import Wenku8Core

/// The books whose metadata is cached, so the reader can see what is stored and drop it.
///
/// Metadata is kept separately from downloads: a book can be readable offline in every
/// sense except its chapters, and that still occupies space. Listing them makes the figure
/// in Settings actionable instead of a bare number.
struct MetadataCacheView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var store: LibraryStore
    @State private var entries: [OfflineStore.Entry] = []
    /// The entry just removed, kept so the deletion can be taken back.
    @State private var undoEntry: OfflineStore.Entry?
    @State private var undoToken = UUID()
    /// Set when the reader asks to drop the whole "其他缓存" group.
    @State private var pendingClearAll = false
    /// Cover files stored on this device, keyed by book.
    @State private var localCovers: [Int: URL] = [:]

    /// Three kinds, in the order they matter to the reader.
    ///
    /// Entries the reader cannot afford to lose are not offered for deletion: a shelf book
    /// needs its metadata to render offline, and a downloaded book's metadata belongs with
    /// its chapters. Only books that were merely opened can be dropped.
    enum Kind: String, CaseIterable, Identifiable {
        case shelf
        case downloaded
        case opened

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shelf: return "书架书籍"
            case .downloaded: return "已下载书籍"
            case .opened: return "其他缓存"
            }
        }

        /// Whether the reader may delete this kind of entry.
        var isDeletable: Bool {
            switch self {
            case .shelf, .downloaded: return false
            case .opened: return true
            }
        }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: "tray",
                        title: "还没有元数据缓存",
                        message: "书架上的书籍会自动缓存元数据，断网时也能看到书名、封面和简介。"
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(Kind.allCases) { kind in
                    let items = grouped[kind] ?? []
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { entry in
                                row(entry)
                                    // A confirmed delete must not be `onDelete`: that
                                    // removes the row itself as soon as the swipe ends,
                                    // without waiting for the data. The rows below slid up
                                    // into the gap and dropped back when the list redrew
                                    // with the entry still present. `swipeActions` only
                                    // arms the button, so nothing moves until the delete
                                    // actually happens.
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if kind.isDeletable {
                                            Button(role: .destructive) {
                                                delete(entry)
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                            if kind.isDeletable, !items.isEmpty {
                                // One entry per book is fine for a few, but clearing the
                                // whole group should not require swiping them one by one.
                                Button(role: .destructive) {
                                    pendingClearAll = true
                                } label: {
                                    Label("清除全部", systemImage: "trash")
                                }
                            }
                        } header: {
                            Text(kind.title)
                        } footer: {
                            if !kind.isDeletable {
                                Text(kind == .shelf
                                    ? "书架上的书会保留元数据，以便离线查看。"
                                    : "已下载书籍的元数据随书籍保留。")
                            }
                        }
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("共 \(entries.count) 本 · \(totalLabel)")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let undoEntry {
                HStack(spacing: 12) {
                    Text("已删除「\(undoEntry.title)」")
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("撤销") { undoDelete() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("元数据缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .alert("清除全部？", isPresented: $pendingClearAll) {
            Button("清除", role: .destructive) { Task { await clearOpened() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除既不在书架、也没下载过正文的书籍元数据，共 \(grouped[.opened]?.count ?? 0) 本。书架书籍和已下载书籍不受影响。")
        }
    }

    /// Drops the metadata of every book that is neither on the shelf nor downloaded.
    ///
    /// Shelf and downloaded books are excluded by the same rule the rows use, so this can
    /// never remove something the reader needs offline.
    private func clearOpened() async {
        for entry in grouped[.opened] ?? [] {
            await OfflineStore.shared.delete(entry.novelID)
        }
        await refresh()
    }

    private func row(_ entry: OfflineStore.Entry) -> some View {
        Button {
            router.open(.novel(entry.novelID))
        } label: {
            HStack(spacing: 12) {
                // The stored file, not the remote URL: this screen is about what is held
                // offline, and loading the thumbnail over the network showed a picture the
                // app did not actually have.
                CoverCard(
                    url: localCovers[entry.novelID] ?? entry.detail?.coverURL,
                    title: entry.title,
                    width: 40,
                    height: 56
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let author = entry.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(cachedSummary(entry))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What this entry actually holds: a description of its metadata, plus chapters when
    /// the book is also downloaded.
    private func cachedSummary(_ entry: OfflineStore.Entry) -> String {
        var parts: [String] = []
        if entry.detail != nil { parts.append("元数据") }
        if !entry.storedChapterIDs.isEmpty {
            parts.append("\(entry.storedChapterIDs.count) 章")
        }
        parts.append(formatBytes(entry.bytes))
        return parts.joined(separator: " · ")
    }

    /// The entries of each kind.
    ///
    /// A book can be both on the shelf and downloaded; it is reported once, as downloaded,
    /// because that is the stronger claim about what is on the device.
    private var grouped: [Kind: [OfflineStore.Entry]] {
        let shelfIDs = Set(account.remoteShelf.map(\.novel.id)).union(store.saved.map(\.id))
        var result: [Kind: [OfflineStore.Entry]] = [:]
        for entry in entries {
            let kind: Kind
            if !entry.storedChapterIDs.isEmpty {
                kind = .downloaded
            } else if shelfIDs.contains(entry.novelID) {
                kind = .shelf
            } else {
                kind = .opened
            }
            result[kind, default: []].append(entry)
        }
        return result
    }

    private var totalLabel: String {
        formatBytes(entries.reduce(0) { $0 + $1.bytes })
    }

    /// Removes a row without the bounce the alert used to cause.
    ///
    /// Two animations were fighting: the alert closing, and the list removing the row it
    /// was showing. The row slid up, was put back by the other animation, and slid up
    /// again. So the alert is allowed to finish closing first, and the list is then changed
    /// in a single step with no animation of its own — the rows below settle once, in place.
    /// Removes a row straight from the swipe, keeping it for undo.
    ///
    /// This used to ask first, in an alert, and that alert is what made the list bounce: it
    /// is modal, and dismissing it while the list removed the row underneath ran two
    /// animations over the same pixels — the rows below jumped up and dropped back, whatever
    /// the list itself did, and the bounce survived removing the animation and delaying the
    /// change.
    ///
    /// The deletion is cheap and self-healing — the book is cached again the next time its
    /// shelf loads — so it does not need a question, it needs a way back. The undo bar is
    /// that, and nothing here is modal.
    private func delete(_ entry: OfflineStore.Entry) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            entries.removeAll { $0.novelID == entry.novelID }
        }
        Task {
            await OfflineStore.shared.delete(entry.novelID)
            await refresh()
        }
        withAnimation(.easeOut(duration: 0.2)) { undoEntry = entry }
        scheduleUndoExpiry()
    }

    /// Puts a removed entry back exactly as it was.
    private func undoDelete() {
        guard let entry = undoEntry else { return }
        undoEntry = nil
        OfflineStore.shared.saveManifest(entry)
        entries.append(entry)
        Task { await refresh() }
    }

    /// Drops the undo bar after a few seconds, so it does not sit there forever.
    private func scheduleUndoExpiry() {
        let token = UUID()
        undoToken = token
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard undoToken == token else { return }
            withAnimation(.easeIn(duration: 0.2)) { undoEntry = nil }
        }
    }

    private func refresh() async {
        // Metadata-only: a downloaded book has its own screen.
        // Downloads appear here too: their metadata is part of the same cache, and hiding
        // them made the counts disagree with Settings.
        entries = await OfflineStore.shared.entries().filter { $0.detail != nil }
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
