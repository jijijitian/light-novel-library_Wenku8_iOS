import SwiftUI
import Wenku8Core

@MainActor
final class NovelDetailViewModel: ObservableObject {
    @Published private(set) var detail: NovelDetail?
    @Published private(set) var volumes: [Volume] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingVolumes = false
    @Published private(set) var error: Error?
    /// Why the catalogue could not be loaded, shown on the page instead of being swallowed.
    @Published private(set) var volumesError: Error?

    private let service: NovelService
    private var loaded = false
    /// Identifies the current load, so a superseded one cannot write over its result.
    private var generation = 0

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    /// Loads a book's page.
    ///
    /// Cached metadata is the whole story on a normal visit: the page renders from it and
    /// the network is left alone. Refreshing behind the reader's back changed the page
    /// under them for no request they made. A book with nothing cached fetches once, and
    /// after that only an explicit pull-to-refresh reaches the network.
    func load(novelID: Int, force: Bool = false) async {
        guard force || !loaded else { return }
        // A forced refresh supersedes a load already in flight instead of being dropped by
        // it. It used to return here, so a pull while the first load was still running did
        // nothing at all — the spinner turned and the page stayed empty.
        if isLoading && !force { return }

        generation &+= 1
        let mine = generation
        isLoading = true
        defer { if generation == mine { isLoading = false } }

        if !force, let cached = await service.cachedDetail(aid: novelID) {
            // Book and catalogue both come from the cache: the catalogue is part of the
            // metadata now, so a book opened once is complete offline.
            guard generation == mine else { return }
            detail = cached
            // A cached book whose cover was never stored still points at the remote image;
            // store it in the background so the next visit is fully offline.
            Task { await service.ensureCachedCover(aid: novelID) }
            let stored = await service.cachedVolumes(aid: novelID) ?? []
            if !stored.isEmpty {
                volumes = stored
                loaded = true
                isLoadingVolumes = false
                return
            }
            // The book is known but its catalogue was never stored — every shelf book
            // cached before catalogues were saved. Show the book at once and fetch the
            // catalogue behind it, instead of returning a page with no chapters and
            // waiting for the reader to guess that a refresh would help.
            loaded = true
            isLoadingVolumes = true
            do {
                let fetched = try await service.fetchVolumes(aid: novelID)
                if generation == mine {
                    volumes = fetched
                    volumesError = nil
                }
            } catch {
                if generation == mine { volumesError = error }
            }
            if generation == mine { isLoadingVolumes = false }
            return
        }

        async let detailTask = service.fetchDetail(aid: novelID)
        async let volumesTask = service.fetchVolumes(aid: novelID)
        do {
            let fetched = try await detailTask
            if generation == mine {
                detail = fetched
                error = nil
                loaded = true
            }
        } catch {
            if generation == mine, detail == nil { self.error = error }
        }
        do {
            let result = try await volumesTask
            if generation == mine {
                volumes = result
                volumesError = nil
            }
        } catch {
            if generation == mine { volumesError = error }
        }
        if generation == mine { isLoadingVolumes = false }
    }

    /// A user-initiated refresh: re-reads the book from the service.
    /// Minimum time the refresh indicator stays up, matching the home screen.
    private static let minimumRefreshDuration: Duration = .milliseconds(1200)

    func refresh(novelID: Int) async {
        // Same floor as the home screen: a warm refresh otherwise finishes in a few
        // hundred milliseconds and the spinner retracts before it registers, which reads
        // as "the pull did nothing". Polled rather than a single sleep, because a
        // cancelled sleep returns immediately.
        // Outside this task's cancellation: `.refreshable` cancels its closure when the
        // control retracts, and a cancelled task cannot finish a fetch. An unstructured
        // task does not inherit that cancellation.
        let started = ContinuousClock.now
        loaded = false
        let work = Task { await self.load(novelID: novelID, force: true) }
        await work.value
        let deadline = started + Self.minimumRefreshDuration
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

struct NovelDetailView: View {
    var novelID: Int
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var account: AccountStore
    @StateObject private var model = NovelDetailViewModel()
    @State private var showFullIntro = false
    @State private var showLogin = false
    @State private var shelfMessage: String?
    @State private var webItem: WebSheetItem?
    @StateObject private var downloadManager = OfflineDownloadManager.shared
    @State private var offlineEntry: OfflineStore.Entry?
    @State private var showVolumePicker = false
    @AppStorage(CoverPalette.storageKey) private var coverTint = false
    @State private var palette: CoverPalette?

    var body: some View {
        ScrollView {
            if let detail = model.detail {
                content(detail)
            } else if model.isLoading {
                LoadingRow(text: "正在载入小说信息…")
            } else if let error = model.error {
                ErrorStateView(error: error) {
                    Task { await model.load(novelID: novelID, force: true) }
                }
            }
        }
        .background {
            // Tinted by the cover when the reader asked for it; the plain backdrop
            // otherwise, so the switch has a visible effect either way.
            TintedBackground(palette: coverTint ? palette : nil)
        }
        .navigationTitle(model.detail?.title ?? "小说信息")
        .sheet(isPresented: $showVolumePicker) {
            VolumePickerSheet(
                title: model.detail?.title ?? "选择分卷",
                volumes: model.volumes,
                onConfirm: { ids in
                    downloadManager.download(novelID: novelID, volumeIDs: ids)
                },
                storedChapterIDs: offlineEntry?.storedChapterIDs ?? []
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Adding offers the site's shelf groups; the toolbar button toggles
                // for a quick save, while this menu places the book deliberately.
                Menu {
                    if isOnShelf {
                        Button(role: .destructive) {
                            removeFromShelf()
                        } label: {
                            Label("移出书架", systemImage: "bookmark.slash")
                        }
                    } else if account.isSignedIn {
                        ForEach(account.shelfGroups) { group in
                            Button {
                                addToShelf(classID: group.classID)
                            } label: {
                                Label(group.title, systemImage: "books.vertical")
                            }
                        }
                    } else {
                        Button {
                            addToShelf(classID: nil)
                        } label: {
                            Label("加入本地书架", systemImage: "bookmark")
                        }
                    }
                } label: {
                    Image(systemName: isOnShelf ? "bookmark.fill" : "bookmark")
                }
                .disabled(model.detail == nil)
                .accessibilityLabel(isOnShelf ? "移出书架" : "加入书架")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        downloadManager.download(novelID: novelID)
                    } label: {
                        // "重新下载" only once chapters exist. A book with metadata only has
                        // nothing to re-download, and offering it implied a download that
                        // had never happened.
                        Label(
                            offlineEntry?.downloadState == nil ? "下载到本机" : "重新下载",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(downloadManager.isDownloading)

                    // The Android app offers a per-volume choice; without it a long series
                    // is all-or-nothing.
                    if !model.volumes.isEmpty {
                        Button {
                            showVolumePicker = true
                        } label: {
                            Label("选择分卷下载", systemImage: "list.bullet.indent")
                        }
                        .disabled(downloadManager.isDownloading)
                    }

                    if offlineEntry?.downloadState != nil {
                        Button(role: .destructive) {
                            Task {
                                await downloadManager.delete(novelID)
                                await refreshOffline()
                            }
                        } label: {
                            Label("删除本地缓存", systemImage: "trash")
                        }
                    }

                    Button {
                        webItem = WebSheetItem(url: SiteDomain.current.webURL("/book/\(novelID).htm"))
                    } label: {
                        Label("在网页版打开", systemImage: "safari")
                    }
                    Button {
                        Task { await model.load(novelID: novelID, force: true) }
                    } label: {
                        Label("刷新信息", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // Pull-to-refresh is the only path to the network on a book that is already
        // cached; the same system indicator as the home screen.
        .refreshable { await model.refresh(novelID: novelID) }
        .task {
            if let entry = await OfflineStore.shared.entry(for: novelID) {
                cachedChapterIDs = entry.storedChapterIDs
                pendingPictureIDs = entry.pendingPictureIDs ?? []
            }
            await loadPalette()
            await model.load(novelID: novelID)
            await refreshOffline()
            // The cover URL is only known once the book has loaded; the first pass could
            // rely on the stored image alone.
            if palette == nil { await loadPalette() }
            // Ensures the bookmark shows the truth for books that are on the website's
            // shelf but were never added on this device.
            if account.remoteShelf.isEmpty {
                account.restoreCachedShelf()
            }
        }
        .onChange(of: downloadManager.progress) { _, newValue in
            // Every step, not only the last: the catalogue's per-chapter and per-volume
            // marks are the only feedback while a download runs.
            Task { await refreshOffline() }
            if newValue == nil { Task { await refreshOffline() } }
        }
        .sheet(item: $webItem) { item in
            WebSheet(url: item.url)
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .alert("书架", isPresented: Binding(
            get: { shelfMessage != nil },
            set: { if !$0 { shelfMessage = nil } }
        )) {
            Button("知道了") { shelfMessage = nil }
            if !account.isSignedIn {
                Button("去登录") {
                    shelfMessage = nil
                    showLogin = true
                }
            }
        } message: {
            Text(shelfMessage ?? "")
        }
    }

    @ViewBuilder
    private func content(_ detail: NovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(detail)
            if detail.isRestricted {
                restrictedNotice
            }
            if let tags = detail.tags, !tags.isEmpty {
                tagsRow(tags)
            }
            introCard(detail)
            reviewsCard
            if !model.volumes.isEmpty {
                chaptersCard
            } else if model.isLoading || model.isLoadingVolumes {
                LoadingRow(text: "正在载入目录…")
            } else {
                // Never leave the page silently without a catalogue: say so and offer the
                // one action that fixes it.
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(
                        title: "章节目录",
                        subtitle: "暂时无法载入",
                        symbol: "list.bullet.rectangle"
                    )
                    if let reason = model.volumesError {
                        Text(reason.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.refresh(novelID: novelID) }
                    } label: {
                        Label("重新载入目录", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .secondaryGlassButtonShape()
                }
                .padding(16)
                .glassCard(cornerRadius: 22)
            }
            if !detail.recommendations.isEmpty {
                recommendations(detail.recommendations)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 30)
    }

    /// Reads the cover's colours, using the stored image so opening a book does not fetch
    /// the cover again just to look at it.
    private func loadPalette() async {
        guard coverTint else {
            palette = nil
            return
        }
        let remote = model.detail?.coverURL
        palette = await CoverPalette.palette(for: novelID, remoteURL: remote)
    }

    private func refreshOffline() async {
        let entry = await OfflineStore.shared.entry(for: novelID)
        offlineEntry = entry
        cachedChapterIDs = entry?.storedChapterIDs ?? []
        pendingPictureIDs = entry?.pendingPictureIDs ?? []
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func header(_ detail: NovelDetail) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CoverCard(url: detail.coverURL, title: detail.title, width: 112, height: 158)
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.author.isEmpty {
                    Label(detail.author, systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !detail.status.isEmpty {
                        TagChip(text: detail.status, systemImage: "circle.fill")
                    }
                    if !detail.category.isEmpty {
                        TagChip(text: detail.category, systemImage: "building.columns")
                    }
                }
                if !detail.wordCount.isEmpty {
                    Label(detail.wordCount, systemImage: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !detail.updatedAt.isEmpty {
                    Label("更新于 \(detail.updatedAt)", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(cornerRadius: 24)
    }

    @ViewBuilder
    private func introCard(_ detail: NovelDetail) -> some View {
        if !detail.intro.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "内容简介", symbol: "text.book.closed")
                Text(detail.intro)
                    .font(.subheadline)
                    .lineSpacing(4)
                    .lineLimit(showFullIntro ? nil : 4)
                Button(showFullIntro ? "收起" : "展开全部") {
                    withAnimation(.snappy(duration: 0.2)) { showFullIntro.toggle() }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            .padding(16)
            .glassCard(cornerRadius: 22)
        }
    }

    /// True while a volume is being fetched because a chapter of it is being read.
    private var isAutomaticFetch: Bool {
        downloadManager.automaticBusyChapterID != nil
    }

    /// Whether this chapter is the one being fetched right now.
    private var downloadingChapterID: Int? {
        guard let progress = downloadManager.progress, progress.novelID == novelID else {
            return nil
        }
        return progress.currentChapterID
    }

    /// Aggregate state of a volume: downloading if any chapter is in flight, complete when
    /// every chapter is stored, empty when none is.
    @ViewBuilder
    private func volumeStatusIcon(_ volume: Volume) -> some View {
        let ids = Set(volume.chapters.map(\.id))
        let downloading = !isAutomaticFetch && (downloadingChapterID.map { ids.contains($0) } ?? false)
        let stored = volume.chapters.filter { cachedChapterIDs.contains($0.id) }.count
        if downloading {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
                .accessibilityLabel("正在下载")
        } else if stored > 0 && stored == volume.chapters.count {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .frame(width: 16, height: 16)
                .accessibilityLabel("已下载")
        } else if stored > 0 {
            Image(systemName: "circle.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityLabel("部分下载")
        } else if isInOfflineCache {
            // The book has a download, so which volumes are still missing is a question
            // worth answering on every volume.
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .frame(width: 16, height: 16)
                .accessibilityLabel("未下载")
        } else {
            // Nothing of this book is downloaded: a column of empty circles would report
            // "not downloaded" for every volume and say nothing. The width is reserved so
            // titles stay aligned.
            Color.clear
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }

    /// Whether any part of this book is downloaded.
    ///
    /// The volume markers are per *book*, not per volume: a book that is not in the offline
    /// cache shows none, and one that is shows every volume's state including the empty
    /// circles.
    private var isInOfflineCache: Bool {
        !cachedChapterIDs.isEmpty
    }

    /// Leading status for a chapter row.
    @ViewBuilder
    private func chapterStatusIcon(_ chapterID: Int) -> some View {
        // Only a queued download turns a chapter's tick into a spinner. A volume being fetched
        // because it is being read is not a download of that chapter, and showing it as one
        // made the tick spin and then settle every time the chapter was opened.
        if downloadingChapterID == chapterID, !isAutomaticFetch {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
                .accessibilityLabel("正在下载")
        } else if pendingPictureIDs.contains(chapterID) {
            // The text is on disk and the pictures are still coming: a spinner is the honest
            // mark, because the chapter is not readable offline yet.
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
                .accessibilityLabel("正在下载插图")
        } else if cachedChapterIDs.contains(chapterID) {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .frame(width: 16, height: 16)
                .accessibilityLabel("已下载")
        } else {
            // Chapters always report: "this one is not stored" is the question the list
            // answers row by row, whether or not the book has any download at all.
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .frame(width: 16, height: 16)
                .accessibilityLabel("未下载")
        }
    }

    /// Entry to this book's review list.
    /// The book's tags, each one opening the site's list for it.
    @ViewBuilder
    private func tagsRow(_ tags: [NovelTag]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    Button {
                        openTag(tag)
                    } label: {
                        TagChip(text: tag.name, systemImage: "number")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// Opens a tag's book list.
    private func openTag(_ tag: NovelTag) {
        router.open(.tag(tag.name))
    }

    /// Shown when the site delisted the book.
    ///
    /// Its pages are empty, but the text is still published one volume at a time as a
    /// download. Opening a chapter fetches that volume and keeps it, so the notice says the
    /// first read costs a download rather than that the book is unavailable.
    private var restrictedNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("因版权问题已下架", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text("文库不再提供这本书的在线阅读，但站点仍提供分卷下载。App 会在阅读时自动下载所在分卷，下载后会保留在本机。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 22)
    }

    private var reviewsCard: some View {
        Button {
            router.open(.reviews(novelID))
        } label: {
            HStack(spacing: 12) {
                SectionHeader(
                    title: "书评",
                    subtitle: "看看大家怎么说",
                    symbol: "text.bubble"
                )
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22)
        }
        .buttonStyle(.plain)
    }

    private var chaptersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(
                    title: "章节目录",
                    subtitle: "共 \(model.volumes.flatMap(\.chapters).count) 章",
                    symbol: "list.bullet.rectangle"
                )
                Button {
                    startReading()
                } label: {
                    Label("开始阅读", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                }
                .prominentGlassButtonShape()
                .tint(AppTheme.accent)
            }

            ForEach(model.volumes) { volume in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(volume.chapters.enumerated()), id: \.element.id) { index, chapter in
                            Button {
                                openChapter(volume: volume, index: index)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    // Status leads the row: a spinner while this chapter is
                                    // being fetched, a download mark once it is on disk, and
                                    // an empty circle when it is not. Reading position stays
                                    // at the trailing edge so the two never compete.
                                    chapterStatusIcon(chapter.id)
                                    // The number separates chapters at a glance and gives the
                                    // list a left edge to read down; the title stays the only
                                    // thing at full weight.
                                    Text("\(index + 1)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 18, alignment: .trailing)
                                    Text(chapter.title)
                                        .font(.footnote)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if store.progress(for: novelID)?.chapterID == chapter.id {
                                        Image(systemName: "bookmark.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(.vertical, 9)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(store.progress(for: novelID)?.chapterID == chapter.id
                                              ? AnyShapeStyle(.tint.opacity(0.12))
                                              : AnyShapeStyle(.clear))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 8) {
                        // The volume carries its own state, so a collapsed volume still
                        // shows whether it is being fetched, stored, or neither.
                        volumeStatusIcon(volume)
                        Text(volume.title)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .tint(.primary)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }

    private func recommendations(_ novels: [NovelSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "同类推荐", symbol: "sparkles")
            NovelGrid(novels: Array(novels.prefix(6))) { novel in
                router.open(.novel(novel.id))
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }

    /// Chapters of this book that are stored on the device.
    @State private var cachedChapterIDs = Set<Int>()
    /// Chapters whose text is stored but whose pictures are still arriving.
    @State private var pendingPictureIDs = Set<Int>()

    /// Whether this book is on the shelf, checking the account as well.
    ///
    /// The icon used to look at the local list only, so books already on the website's
    /// shelf showed as "not added" until the reader added them a second time.
    private var isOnShelf: Bool {
        store.isSaved(novelID) || account.remoteShelf.contains { $0.novel.id == novelID }
    }

    /// Saves locally and, when signed in, on the site — into `classID` when given.
    private func addToShelf(classID: Int?) {
        guard let detail = model.detail else { return }
        let summary = NovelSummary(
            id: detail.id,
            title: detail.title,
            author: detail.author,
            coverURL: detail.coverURL
        )
        guard account.isSignedIn else {
            // No account: the local shelf is the shelf.
            store.add(summary)
            shelfMessage = "已加入本地书架"
            return
        }
        // Signed in, the account's shelf is the single list the app shows, so the book
        // is added there. If that fails the book is still stored locally, which is both
        // what the reader expects ("I added it") and what lets the next sync upload it
        // — dropping it would lose the book on a network blip.
        Task {
            let message = await account.addToRemoteShelf(summary, classID: classID)
            let onAccount = account.remoteShelf.contains { $0.novel.id == summary.id }
            if onAccount {
                account.loadCachedShelf(classID: account.selectedShelfClass)
            } else {
                store.add(summary)
            }
            shelfMessage = message
        }
    }

    private func removeFromShelf() {
        guard let detail = model.detail else { return }
        store.remove(detail.id)
        guard account.isSignedIn else {
            shelfMessage = "已从本地书架移除"
            return
        }
        Task { shelfMessage = await account.removeFromRemoteShelf(detail.id) }
    }

    private func allChapters() -> [ChapterLink] {
        model.volumes.flatMap(\.chapters)
    }

    private func startReading() {
        let chapters = allChapters()
        guard !chapters.isEmpty else { return }
        let saved = store.progress(for: novelID)?.chapterID
        let index = chapters.firstIndex { $0.id == saved } ?? 0
        router.open(.reader(novelID: novelID, chapters: chapters, startIndex: index))
    }

    private func openChapter(volume: Volume, index: Int) {
        let chapters = allChapters()
        guard let start = chapters.firstIndex(where: { $0.id == volume.chapters[index].id }) else { return }
        router.open(.reader(novelID: novelID, chapters: chapters, startIndex: start))
    }
}
