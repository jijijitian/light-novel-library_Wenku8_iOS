import SwiftUI
import Wenku8Core

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var rows: [HomeRow] = []
    /// Starts true: the first render happens before `.task` runs, so a false initial
    /// value showed one frame of empty page before the skeleton appeared.
    @Published private(set) var isLoading = true
    /// Guards against overlapping fetches, separately from the display flag.
    private var isFetching = false
    @Published private(set) var error: Error?
    @Published private(set) var lastUpdated: Date?

    private let service: NovelService
    private var hasLoaded = false

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        // No re-entry guard on `isLoading`: it starts true so the skeleton is drawn from
        // the first frame, and guarding on it would mean the initial load never ran.
        guard !isFetching else { return }
        isFetching = true
        isLoading = true
        rows = []
        defer {
            isLoading = false
            isFetching = false
        }

        // Rows are appended as each section arrives, top-down, so the top of the page is
        // readable while the rest is still loading rather than after the slowest section.
        let collected = await service.homeRowsStreaming { [weak self] row in
            guard let self else { return }
            await MainActor.run {
                if !self.rows.contains(where: { $0.section == row.section }) {
                    self.rows.append(row)
                }
            }
        }
        rows = collected
        error = rows.isEmpty ? Wenku8Error.unavailable("首页内容暂时无法载入") : nil
        lastUpdated = Date()
        hasLoaded = true
    }
}

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var model = HomeViewModel()
    @State private var heroIndex = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Five fixed slots, each owns its own placeholder. A section that is still
                // loading shows its skeleton in place rather than shifting the page: the
                // previous version wrapped the whole page in one "loading or loaded" branch,
                // so nothing appeared until the first row arrived and everything else moved
                // down when it did.
                heroSlot
                continueReading
                ForEach(HomeSection.allCases) { section in
                    sectionSlot(section)
                }

                if let error = model.error, model.rows.isEmpty {
                    ErrorStateView(error: error) {
                        Task { await model.reload() }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("轻小说文库")
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
    }

    /// The banner, or its placeholder while the first section is on its way.
    @ViewBuilder
    private var heroSlot: some View {
        if !heroNovels.isEmpty {
            HeroBanner(novels: heroNovels, selection: $heroIndex) { novel in
                router.open(.novel(novel.id))
            }
        } else if model.isLoading {
            RoundedRectangle(cornerRadius: 26)
                .fill(.quaternary)
                .frame(height: 200)
                .redacted(reason: .placeholder)
        }
    }

    /// One section: its heading, then its six covers or six placeholders.
    private func sectionSlot(_ section: HomeSection) -> some View {
        let row = model.rows.first { $0.section == section }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    title: section.title,
                    subtitle: section.subtitle,
                    symbol: section.symbol
                )
                if row != nil {
                    Button {
                        router.open(.rankList(section.board))
                    } label: {
                        Text("更多")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            if let row, !row.items.isEmpty {
                NovelGrid(novels: Array(row.items.prefix(6))) { novel in
                    router.open(.novel(novel.id))
                }
            } else if model.isLoading {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 14)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(0..<6, id: \.self) { _ in
                        PlaceholderGridCell()
                    }
                }
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            } else {
                // Settled with nothing to show: say so instead of pulsing forever.
                Text("暂时没有内容")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var heroNovels: [NovelSummary] {
        let items = model.rows.first(where: { $0.section == .hot })?.items ?? []
        return Array(items.prefix(3))
    }

    @ViewBuilder
    private var continueReading: some View {
        if let entry = store.progress.values.sorted(by: { $0.updated > $1.updated }).first,
           let novel = store.saved.first(where: { $0.id == entry.novelID }) {
            Button {
                router.open(.novel(novel.id))
            } label: {
                HStack(spacing: 12) {
                    CoverCard(url: novel.coverURL, title: novel.title, width: 52, height: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("继续阅读").font(.caption).foregroundStyle(.secondary)
                        Text(novel.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(entry.chapterTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .padding(12)
                .glassCard(cornerRadius: 20)
            }
            .buttonStyle(.plain)
        }
    }
}

struct HeroBanner: View {
    var novels: [NovelSummary]
    @Binding var selection: Int
    var onSelect: (NovelSummary) -> Void

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $selection) {
                ForEach(Array(novels.enumerated()), id: \.element.id) { index, novel in
                    ZStack {
                        AppTheme.gradient(for: novel.id)
                        HStack(alignment: .center, spacing: 18) {
                            CoverCard(url: novel.coverURL, title: novel.title, width: 104, height: 148)
                                .rotation3DEffect(.degrees(-6), axis: (x: 0, y: 1, z: 0))
                                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("编辑推荐")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .glassCapsule()

                                Text(novel.title)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .shadow(radius: 4, y: 1)

                                if let author = novel.author, !author.isEmpty {
                                    Text(author)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)

                                // Sits right under the author line instead of being
                                // pushed to the card's bottom edge, so it can never
                                // collide with the page indicator below the card.
                                Label("查看详情", systemImage: "chevron.right.circle.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                    }
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .tag(index)
                    .onTapGesture { onSelect(novel) }
                }
            }
            // The system page indicator is drawn *inside* the paged TabView, which
            // is why it used to sit on top of the card. It is disabled here and
            // re-drawn below the card instead, so the dots always get their own row.
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 8)

            if novels.count > 1 {
                PageDots(count: novels.count, selection: selection)
            }
        }
    }
}

/// Custom page indicator, tinted to match the hero card gradients.
struct PageDots: View {
    var count: Int
    var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? AppTheme.accent : Color.primary.opacity(0.22))
                    .frame(width: index == selection ? 16 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: selection)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .systemBackground).opacity(0.92),
                    Color(uiColor: .secondarySystemBackground).opacity(0.55),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(AppTheme.accent.opacity(0.22))
                .frame(width: 260, height: 260)
                .blur(radius: 80)
                .offset(x: -120, y: -260)
            Circle()
                .fill(Color.orange.opacity(0.16))
                .frame(width: 240, height: 240)
                .blur(radius: 90)
                .offset(x: 140, y: 300)
        }
        .ignoresSafeArea()
    }
}
