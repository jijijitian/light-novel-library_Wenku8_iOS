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
    /// The load started by `startLoadingIfNeeded`, so a refresh can supersede it.
    private var loadTask: Task<Void, Never>?
    /// Monotonic counter identifying the current load.
    private var generation = 0
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

    /// A user-initiated refresh: always performs a fetch, even if one is in flight.
    ///
    /// The in-flight load is cancelled first, because letting two run would halve the
    /// throttle slots between them and make both slower; the reader asked for a refresh,
    /// so their request wins.
    /// Minimum time the refresh indicator stays up.
    ///
    /// A refresh over a warm connection can finish in a few hundred milliseconds, and the
    /// indicator retracted before the reader could see it — indistinguishable from the
    /// gesture being ignored. The wait is a floor, not a delay: a slow refresh is not
    /// extended by it.
    private static let minimumRefreshDuration: Duration = .milliseconds(1200)

    func refresh() async {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        isFetching = false

        // The fetch must not inherit this task's cancellation. `.refreshable` runs its
        // closure in a task SwiftUI cancels when the control retracts, and retracting is
        // what happens as soon as the content is rebuilt — which this refresh causes by
        // publishing rows. The sections then hit `Task.isCancelled` and returned nothing,
        // so the spinner turned while the page kept its old books.
        //
        // An unstructured `Task` does not inherit cancellation, so the work finishes.
        let started = ContinuousClock.now
        let work = Task { await self.reload() }
        await work.value
        let deadline = started + Self.minimumRefreshDuration
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Fires a refresh a few seconds after launch and logs what each row holds, so a
    /// pull-to-refresh can be exercised and checked without driving the gesture by hand.
    ///
    ///     --environment-variables '{"WENKU8_AUTO_REFRESH":"1"}'
    ///
    /// Declared unconditionally so the modifier that calls it needs no compile-time guard;
    /// the body is empty outside debug builds.
    func debugAutoRefreshIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["WENKU8_AUTO_REFRESH"] != nil else { return }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        logRows("before")
        // Reproduce what SwiftUI does to a `.refreshable` closure: cancel its task while it
        // is running. If the fetch inherited that cancellation, no row would be delivered.
        let pull = Task { await refresh() }
        pull.cancel()
        await pull.value
        logRows("after cancelled refresh")
        #endif
    }

    #if DEBUG
    private func logRows(_ label: String) {
        let summary = rows.map { row in
            "\(row.section.rawValue):" + row.items.prefix(3).map { "\($0.id)" }.joined(separator: ",")
        }.joined(separator: " | ")
        print("[home] \(label) -> \(summary)")
    }
    #endif

    /// Starts the first load detached from the view's lifetime.
    func startLoadingIfNeeded() {
        guard !hasLoaded, !isFetching else { return }
        loadTask = Task { await reload() }
    }

    /// Reloads the page.
    ///
    /// Existing rows are kept while the refresh runs. Clearing them first made a
    /// pull-to-refresh blank the whole page and then wait for the network — the content
    /// the reader was looking at vanished instead of being replaced. Each section is
    /// swapped as its new copy arrives; a section whose refresh fails keeps what it had.
    func reload() async {
        // No re-entry guard on `isLoading`: it starts true so the skeleton is drawn from
        // the first frame, and guarding on it would mean the initial load never ran.
        guard !isFetching else { return }
        isFetching = true
        // Every load carries a generation. A cancelled load's `defer` runs after its
        // replacement has already started, so without this it would clear the new load's
        // flags and leave the page thinking it is idle.
        generation &+= 1
        let mine = generation
        isLoading = rows.isEmpty
        defer {
            // Only the newest load may clear the flags.
            if generation == mine {
                isLoading = false
                isFetching = false
            }
        }

        // Rows are appended as each section arrives, top-down, so the top of the page is
        // readable while the rest is still loading rather than after the slowest section.
        //
        // The returned collection is deliberately *not* assigned back over `rows`: it is a
        // second, independent description of the same fetch, and a section that failed on
        // the retry is absent from it even though its row was already delivered. Assigning
        // it removed rows that were on screen — the banner would disappear after appearing,
        // because it is built from the first section.
        _ = await service.homeRowsStreaming { [weak self] row in
            guard let self else { return }
            await MainActor.run {
                // Replace the existing row for this section, or append it. Replacing
                // keeps the page in its canonical order as sections come back.
                #if DEBUG
                if ProcessInfo.processInfo.environment["WENKU8_AUTO_REFRESH"] != nil {
                    print("[home] delivered \(row.section.rawValue) \(row.items.count) items")
                }
                #endif
                if let index = self.rows.firstIndex(where: { $0.section == row.section }) {
                    self.rows[index] = row
                } else {
                    self.rows.append(row)
                }
            }
        }
        // Only an empty page is an error; a refresh that kept earlier rows is a partial
        // success and must not replace the page with an error view.
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
        // The system indicator stays up for exactly as long as this closure runs, so the
        // work happens here rather than being handed to a detached task. That is what makes
        // the spinner turn until the refresh has actually finished instead of flashing.
        .refreshable { await model.refresh() }

        // Not `.task`: it is cancelled when the view is rebuilt, which happens when the
        // tab changes or the parent re-renders. The load owns the first section, so
        // cancelling it left 今日热榜 — and the banner built from it — permanently empty
        // until a manual refresh.
        .onAppear { model.startLoadingIfNeeded() }
        .task { await model.debugAutoRefreshIfRequested() }
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
