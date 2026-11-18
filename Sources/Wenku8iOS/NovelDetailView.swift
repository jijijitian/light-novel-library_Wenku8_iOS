import SwiftUI
import Wenku8Core

@MainActor
final class NovelDetailViewModel: ObservableObject {
    @Published private(set) var detail: NovelDetail?
    @Published private(set) var volumes: [Volume] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingVolumes = false
    @Published private(set) var error: Error?

    private let service: NovelService
    private var loaded = false

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(novelID: Int, force: Bool = false) async {
        guard force || !loaded else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let detailTask = service.detail(aid: novelID)
        async let volumesTask = service.volumes(aid: novelID)
        do {
            detail = try await detailTask
            error = nil
            loaded = true
        } catch {
            self.error = error
        }
        if let result = try? await volumesTask {
            volumes = result
        }
        isLoadingVolumes = false
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
        .background { AppBackground() }
        .navigationTitle(model.detail?.title ?? "小说信息")
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
                        Label(
                            offlineEntry == nil ? "下载到本机" : "重新下载",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(downloadManager.isDownloading)

                    if offlineEntry != nil {
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
                        webItem = WebSheetItem(url: URL(string: "https://www.wenku8.net/book/\(novelID).htm"))
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
        .refreshable { await model.load(novelID: novelID, force: true) }
        .task {
            await model.load(novelID: novelID)
            await refreshOffline()
            // Ensures the bookmark shows the truth for books that are on the website's
            // shelf but were never added on this device.
            if account.remoteShelf.isEmpty {
                account.restoreCachedShelf()
            }
        }
        .onChange(of: downloadManager.progress) { _, newValue in
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
            introCard(detail)
            downloadCard
            if !model.volumes.isEmpty {
                chaptersCard
            } else if model.isLoading {
                LoadingRow(text: "正在载入目录…")
            }
            if !detail.recommendations.isEmpty {
                recommendations(detail.recommendations)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 30)
    }

    /// Download state for this book: progress, size, and the offline entry point.
    @ViewBuilder
    private var downloadCard: some View {
        if let progress = downloadManager.progress, progress.novelID == novelID {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("正在下载", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("取消") { downloadManager.cancel() }
                        .font(.caption)
                }
                ProgressView(value: progress.fraction)
                    .tint(AppTheme.accent)
                Text("\(progress.completed)/\(progress.total)  ·  \(progress.currentChapterTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(16)
            .glassCard(cornerRadius: 22)
        } else if let entry = offlineEntry {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(entry.isComplete ? "已下载，可离线阅读" : "部分下载", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(entry.storedChapterIDs.count)/\(entry.chapterIDs.count) 章")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: entry.progress)
                    .tint(AppTheme.accent)
                HStack {
                    Text(formatBytes(entry.bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !entry.isComplete {
                        Button("继续下载") { downloadManager.download(novelID: novelID) }
                            .font(.caption)
                    }
                }
            }
            .padding(16)
            .glassCard(cornerRadius: 22)
        }
    }

    private func refreshOffline() async {
        offlineEntry = await OfflineStore.shared.entry(for: novelID)
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
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(volume.chapters.enumerated()), id: \.element.id) { index, chapter in
                            Button {
                                openChapter(volume: volume, index: index)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(chapter.title)
                                        .font(.subheadline)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                    if store.progress(for: novelID)?.chapterID == chapter.id {
                                        Image(systemName: "bookmark.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(volume.title)
                        .font(.subheadline.weight(.semibold))
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
