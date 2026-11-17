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
    @StateObject private var model = NovelDetailViewModel()
    @State private var showFullIntro = false
    @State private var webItem: WebSheetItem?

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
                Button {
                    if let detail = model.detail {
                        store.toggle(
                            NovelSummary(
                                id: detail.id,
                                title: detail.title,
                                author: detail.author,
                                coverURL: detail.coverURL
                            )
                        )
                    }
                } label: {
                    Image(systemName: store.isSaved(novelID) ? "bookmark.fill" : "bookmark")
                }
                .disabled(model.detail == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
        .task { await model.load(novelID: novelID) }
        .sheet(item: $webItem) { item in
            WebSheet(url: item.url)
        }
    }

    @ViewBuilder
    private func content(_ detail: NovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(detail)
            introCard(detail)
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
