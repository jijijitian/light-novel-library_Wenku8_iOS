import SwiftUI
import Wenku8Core

struct ShelfView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var account: AccountStore

    /// Which shelf books are cached, and how much of them. Read once per appearance.
    @State private var cacheStates: [Int: CacheState] = [:]

    enum CacheState {
        case partial
        case complete
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // One list, not two. Signed in, the account's shelf *is* the shelf: the
                // local list was rendered underneath it as a separate "2 本收藏" block,
                // so a book added here appeared twice and the counts disagreed. The
                // local list is only the shelf when there is no account.
                if account.isSignedIn {
                    cloudShelfSection
                } else if store.saved.isEmpty {
                    emptyState
                } else {
                    localShelfSection
                }

                if !progressNovels.isEmpty {
                    progressSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("我的书架")
        // Entering the page refreshes the cloud shelf, so the app and the website
        // agree on what is on it.
        .task {
            // Paint from cache first, then refresh in the background. Awaiting the
            // network before showing anything made every visit to this tab look like a
            // reload, even when the contents were already on disk.
            account.restoreCachedShelf()
            await loadCacheStates()
            await syncInBackground()
            // Metadata for shelf books is cached so they open offline; the same pass
            // prunes books that have left both the shelf and the device.
            await account.syncShelfMetadata(localIDs: store.saved.map(\.id))
            await loadCacheStates()
            await migrateLegacyLocalShelf()
        }
        .refreshable { await syncNow() }
        .toolbar {
            // The menu listed the *local* list while the screen shows the account's
            // shelf, so signed in it offered books that were not on screen — leftovers
            // from before the two lists were unified — and nothing that was.
            if !account.isSignedIn, !store.saved.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.saved) { novel in
                            Button(role: .destructive) {
                                store.remove(novel.id)
                            } label: {
                                Label(novel.title, systemImage: "minus.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "books.vertical",
            title: "书架还是空的",
            message: "在小说详情页点击「加入书架」，就能在这里追踪阅读进度。",
            actionTitle: "去首页看看"
        ) {
            router.tab = .home
        }
        .padding(.top, 30)
    }

    /// The local shelf, used only when no account is signed in.
    private var localShelfSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TagChip(text: "\(store.saved.count) 本收藏", systemImage: "bookmark.fill")
            NovelGrid(novels: store.saved) { novel in
                router.open(.novel(novel.id))
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 24)
    }

    /// Books with a recorded reading position, from either shelf.
    private var progressNovels: [NovelSummary] {
        let source = account.isSignedIn
            ? account.remoteShelf.map(\.novel)
            : store.saved
        return source.filter { store.progress(for: $0.id) != nil }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "阅读进度", symbol: "timer")
            ForEach(progressNovels) { novel in
                if let progress = store.progress(for: novel.id) {
                    Button {
                        router.open(.novel(novel.id))
                    } label: {
                        HStack(spacing: 12) {
                            CoverCard(url: novel.coverURL, title: novel.title, width: 44, height: 62)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(novel.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(progress.chapterTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(relative(progress.updated))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 22)
    }

    /// The site's shelf, grouped the way the website groups it.
    ///
    /// 默认书架 (classid 0) plus up to five extra shelves. The picker only appears
    /// when the account actually has more than one group, so a simple account is not
    /// shown a control with a single option.
    @ViewBuilder
    private var cloudShelfSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionHeader(title: "文库书架", symbol: "cloud")
                Spacer()
                if account.isSyncingShelf {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        // Full two-way sync, so the local shelf is uploaded too.
                        Task { await syncNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("刷新文库书架")
                }
            }

            // Six Chinese labels do not fit a segmented control at phone width, and
            // SwiftUI silently truncates each segment to an ellipsis. A scrollable
            // chip row keeps every title readable instead.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(account.shelfGroups) { group in
                        shelfGroupChip(group)
                    }
                }
                .padding(.vertical, 2)
            }

            if account.remoteShelf.isEmpty {
                Text(account.isSyncingShelf ? "正在同步…" : "这一组还没有书")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(account.remoteShelf) { entry in
                        Button {
                            router.open(.novel(entry.novel.id))
                        } label: {
                            cloudShelfRow(entry)
                        }
                        .buttonStyle(.plain)
                        if entry.id != account.remoteShelf.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 22)
    }

    /// Offline state for a shelf book: a green tick when fully cached, a half-filled
    /// marker when only some chapters are, nothing when nothing is.
    @ViewBuilder
    private func cacheBadge(for novelID: Int) -> some View {
        if let state = cacheStates[novelID] {
            switch state {
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .accessibilityLabel("已缓存")
            case .partial:
                Image(systemName: "circle.lefthalf.filled")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("部分缓存")
            }
        }
    }

    /// One group selector chip. The selected group is tinted; the rest stay quiet.
    private func shelfGroupChip(_ group: DesktopParser.ShelfGroup) -> some View {
        let isSelected = account.selectedShelfClass == group.classID
        let count = account.shelfGroupCounts[group.classID] ?? group.count
        let label = count > 0 ? "\(group.title) \(count)" : group.title
        return Button {
            Task { await account.selectShelfGroup(group.classID) }
        } label: {
            Text(label)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    Capsule().fill(
                        isSelected ? AppTheme.accent : Color.primary.opacity(0.07)
                    )
                )
        }
        .buttonStyle(.plain)
    }

    /// One cloud-shelf row: cover, title, and the site's recorded latest chapter.
    private func cloudShelfRow(_ entry: ShelfEntry) -> some View {
        HStack(spacing: 12) {
            CoverCard(url: entry.novel.coverURL, title: entry.novel.title, width: 44, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.novel.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let author = entry.novel.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let chapter = entry.latestChapter {
                    Text(chapter.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // The chevron only said "this is a button", which the row already conveys.
            // The space now reports whether the book can be read offline.
            cacheBadge(for: entry.novel.id)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// Two-way sync, passing the local shelf as a single snapshot.
    private func syncNow() async {
        // The recorded chapter per book lets the sync tell a stale row from a current
        // one, so only books that actually moved are refetched.
        account.localChapterIDs = Dictionary(
            uniqueKeysWithValues: store.progress.map { ($0.key, $0.value.chapterID) }
        )
        await account.syncWithLocalShelf(store.saved.map(\.id))
    }

    /// Moves books left in the local list onto the account, then empties it.
    ///
    /// Before the two lists were unified, adding a book wrote it locally even when
    /// signed in, so an account can have books that exist on the device and nowhere
    /// else — invisible on this screen and impossible to remove from it. They are
    /// uploaded first: discarding them would lose the reader's shelf.
    private func migrateLegacyLocalShelf() async {
        guard account.isSignedIn, !store.saved.isEmpty else { return }
        let legacy = store.saved
        for novel in legacy where !account.remoteShelf.contains(where: { $0.novel.id == novel.id }) {
            _ = try? await account.addToRemoteShelf(novel)
        }
        for novel in legacy {
            store.remove(novel.id)
        }
        await syncNow()
    }

    /// Refreshes without clearing what is already on screen.
    ///
    /// `syncWithLocalShelf` only replaces rows when the fetch succeeds, so cached
    /// contents stay visible while the refresh runs rather than flashing to a
    /// placeholder and back.
    private func syncInBackground() async {
        await syncNow()
    }

    /// Reads which shelf books are stored on the device.
    private func loadCacheStates() async {
        let entries = await OfflineStore.shared.entries()
        var states: [Int: CacheState] = [:]
        for entry in entries where !entry.chapterIDs.isEmpty {
            states[entry.novelID] = entry.isComplete ? .complete : .partial
        }
        cacheStates = states
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
