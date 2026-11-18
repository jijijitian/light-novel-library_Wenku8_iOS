import SwiftUI
import Wenku8Core

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var chapters: [ChapterLink]
    @Published var index: Int
    @Published private(set) var content: ChapterContent?
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    let novelID: Int
    private let service: NovelService
    private var cache: [Int: ChapterContent] = [:]
    private var loadToken = UUID()

    init(novelID: Int, chapters: [ChapterLink], startIndex: Int, service: NovelService = NovelService()) {
        self.novelID = novelID
        self.chapters = chapters
        self.index = min(max(0, startIndex), max(0, chapters.count - 1))
        self.service = service
    }

    var current: ChapterLink? {
        guard chapters.indices.contains(index) else { return nil }
        return chapters[index]
    }

    var canGoPrevious: Bool { index > 0 }
    var canGoNext: Bool { index + 1 < chapters.count }

    func load() async {
        guard let chapter = current else { return }
        if let cached = cache[chapter.id] {
            content = cached
            error = nil
            return
        }
        let token = UUID()
        loadToken = token
        isLoading = true
        error = nil
        defer { if loadToken == token { isLoading = false } }
        do {
            let result = try await service.chapter(aid: novelID, cid: chapter.id)
            cache[chapter.id] = result
            guard loadToken == token else { return }
            content = result
        } catch {
            guard loadToken == token else { return }
            self.error = error
        }
    }

    func goPrevious() async {
        guard canGoPrevious else { return }
        index -= 1
        await load()
    }

    func goNext() async {
        guard canGoNext else { return }
        index += 1
        await load()
    }

    func jump(to newIndex: Int) async {
        guard chapters.indices.contains(newIndex) else { return }
        index = newIndex
        await load()
    }

    /// Downloaded copy of an illustration, if any. The lookup is asynchronous, so
    /// results are memoised and a background refresh republishes the view.
    private var localImages: [String: URL] = [:]

    func localImageURL(for remote: URL) -> URL? {
        let key = remote.absoluteString
        if let cached = localImages[key] { return cached }
        Task { [weak self] in
            guard let self else { return }
            guard let local = await OfflineStore.shared.imageURL(for: novelID, remote: remote) else { return }
            await MainActor.run {
                self.localImages[key] = local
                self.objectWillChange.send()
            }
        }
        return nil
    }

    /// Warms the cache for a neighbouring chapter so a page swipe does not show
    /// an empty page while the request is in flight.
    func prefetch(_ newIndex: Int) async {
        guard chapters.indices.contains(newIndex) else { return }
        let chapter = chapters[newIndex]
        guard cache[chapter.id] == nil else { return }
        guard let result = try? await service.chapter(aid: novelID, cid: chapter.id) else { return }
        cache[chapter.id] = result
    }
}

struct ReaderTheme: Equatable {
    var background: Color
    var text: Color

    static let paper = ReaderTheme(
        background: Color(red: 0.98, green: 0.96, blue: 0.91),
        text: Color(red: 0.16, green: 0.14, blue: 0.12)
    )
    static let sepia = ReaderTheme(
        background: Color(red: 0.93, green: 0.88, blue: 0.78),
        text: Color(red: 0.22, green: 0.18, blue: 0.12)
    )
    static let night = ReaderTheme(
        background: Color(red: 0.07, green: 0.07, blue: 0.09),
        text: Color(red: 0.82, green: 0.82, blue: 0.85)
    )
    static let system = ReaderTheme(
        background: Color(uiColor: .systemBackground),
        text: Color(uiColor: .label)
    )

    static let all: [(name: String, theme: ReaderTheme)] = [
        ("纸白", .paper),
        ("护眼", .sepia),
        ("夜间", .night),
        ("跟随系统", .system),
    ]
}

struct ReaderView: View {
    var novelID: Int
    var chapters: [ChapterLink]
    var startIndex: Int

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ReaderViewModel
    @State private var showChrome = true
    @State private var showCatalog = false
    @State private var zoomedImage: ZoomedImage?
    /// Page label fed back by `PagedReadingView` for the collapsed band.
    @State private var pagedPageLabel: String?
    @State private var pagedPageCount = 0
    @State private var requestedPage: Int?

    @AppStorage(ReaderPreferences.themeKey) private var themeName = "纸白"
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = 18.0
    @AppStorage(ReaderPreferences.lineSpacingKey) private var lineSpacing = 8.0
    @AppStorage(ReaderPreferences.layoutKey) private var layoutRaw = ReaderLayout.vertical.rawValue
    @AppStorage(ReaderPreferences.indentKey) private var indentFirstLine = false
    @AppStorage(ReaderPreferences.collapsedInfoKey) private var collapsedInfoEnabled = true
    @AppStorage(ReaderMetrics.topInsetKey) private var topInset = ReaderMetrics.defaultTopInset
    @AppStorage(ReaderMetrics.bottomInsetKey) private var bottomInset = ReaderMetrics.defaultBottomInset

    init(novelID: Int, chapters: [ChapterLink], startIndex: Int) {
        self.novelID = novelID
        self.chapters = chapters
        self.startIndex = startIndex
        _model = StateObject(
            wrappedValue: ReaderViewModel(novelID: novelID, chapters: chapters, startIndex: startIndex)
        )
    }

    /// Height reserved for the custom top bar so prose never runs under it.
    /// The bar is an overlay (it must not touch the safe area, or the text would
    /// reflow when it appears), so the reader reserves this itself.
    static let topBarHeight: CGFloat = 48

    /// Matches Novella's collapsed info: 13pt medium at 45% of the text colour.
    static let collapsedInfoOpacity: Double = 0.45

    private var theme: ReaderTheme {
        ReaderTheme.all.first { $0.name == themeName }?.theme ?? .paper
    }

    private var layout: ReaderLayout {
        ReaderLayout(rawValue: layoutRaw) ?? .vertical
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            switch layout {
            case .vertical:
                verticalContent
            case .horizontal:
                PagedReadingView(
                    model: model,
                    theme: theme,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    indent: indentFirstLine ? ReaderPreferences.indent(for: fontSize) : 0,
                    topInset: topInset + Double(Self.topBarHeight),
                    bottomInset: bottomInset,
                    showChrome: $showChrome,
                    pageLabel: $pagedPageLabel,
                    pageCount: $pagedPageCount,
                    requestedPage: $requestedPage,
                    onLongPressImage: { zoomedImage = ZoomedImage(url: $0) }
                )
            }

            if showChrome {
                topChrome
                    .transition(.opacity.combined(with: .move(edge: .top)))
                chrome
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                collapsedInfo
            }
        }
        .statusBarHidden(!showChrome && collapsedInfoEnabled)
        .navigationBarBackButtonHidden(true)
        // The navigation bar is hidden for good, and the reader draws its own top
        // bar inside the ZStack so it can fade with the control panel.
        //
        // Toggling the *system* bar with `showChrome` was not an option: showing or
        // hiding it changes the top safe area, which reflowed the prose on every
        // tap. A custom overlay affects no layout at all, so the text stays put
        // while the bar still appears and disappears together with the panel.
        .toolbar(.hidden, for: .navigationBar)
        // Reading is a full-screen mode: the tab bar must not sit under the text,
        // otherwise it steals vertical space and clashes with the reader's own
        // glass control bar.
        .toolbar(.hidden, for: .tabBar)
        .task {
            await model.load()
            recordProgress()
        }
        .onChange(of: model.index) { _, _ in
            recordProgress()
        }
        .onDisappear { saveProgress() }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(model: model)
        }
        .sheet(item: $zoomedImage) { item in
            ImageViewer(url: item.url, theme: theme) { zoomedImage = nil }
        }
    }

    // MARK: - Vertical mode

    @ViewBuilder
    private var verticalContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: ChapterPaginator.paragraphSpacing) {
                chapterTitle

                if let content = model.content {
                    blocks(content)
                    navigationButtons
                } else {
                    statusView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            // Both insets are user-tunable and constant regardless of whether the
            // control panel is showing: it floats *over* the prose, so toggling it
            // never reflows a line.
            .padding(.top, Self.topBarHeight + topInset)
            .padding(.bottom, bottomInset)
        }
        .scrollIndicators(.hidden)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) { showChrome.toggle() }
        }
    }

    // MARK: - Shared pieces

    /// Falls back to the loaded chapter's own title when the route did not carry
    /// one, which happens when the reader is opened directly.
    private var displayTitle: String {
        let fromRoute = model.current?.title ?? ""
        if !fromRoute.isEmpty { return fromRoute }
        return model.content?.title ?? ""
    }

    private var chapterTitle: some View {
        // Indented like a paragraph, matching the paged reader.
        Text(indentFirstLine ? "\u{3000}\u{3000}" + displayTitle : displayTitle)
            .font(.title3.weight(.bold))
            .foregroundStyle(theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusView: some View {
        if model.isLoading && model.content == nil {
            ProgressView()
                .tint(theme.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if let error = model.error {
            VStack(spacing: 12) {
                Text(errorMessage(error))
                    .font(.subheadline)
                    .foregroundStyle(theme.text.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await model.load() }
                }
                .prominentGlassButtonShape()
                .tint(AppTheme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    @ViewBuilder
    private func blocks(_ content: ChapterContent) -> some View {
        ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .paragraph(let text):
                // `.padding(.leading:)` would shift the whole paragraph, including
                // wrapped lines. SwiftUI's `Text` has no first-line indent, so the
                // indent is two full-width spaces prefixed to the string — the
                // wrapped lines then start flush, which is what Chinese typesetting
                // expects.
                Text(indentFirstLine ? "\u{3000}\u{3000}" + text : text)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .image(let url):
                // Tapping an illustration must keep doing whatever it did before
                // (nothing beyond the page tap that toggles the chrome); zooming
                // is opt-in via a long press.
                ReaderImage(url: url, theme: theme, localURL: model.localImageURL(for: url))
                    .onLongPressGesture(minimumDuration: 0.45) {
                        zoomedImage = ZoomedImage(url: model.localImageURL(for: url) ?? url)
                    }
            }
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await model.goPrevious()
                    recordProgress()
                }
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .secondaryGlassButtonShape(capsule: false)
            .disabled(!model.canGoPrevious)

            Button {
                Task {
                    await model.goNext()
                    recordProgress()
                }
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .prominentGlassButtonShape()
            .tint(AppTheme.accent)
            .disabled(!model.canGoNext)
        }
        .padding(.top, 26)
    }

    /// Chapter title and page number shown while the menu is hidden.
    ///
    /// Modelled on Novella's `ReaderCollapsedInfo`: plain faint text sitting in the
    /// band the hidden bars would occupy, drawn in the page's own text colour at
    /// 45% opacity so it follows the background and flips with dark mode. It never
    /// intercepts taps, so the whole page still toggles the menu.
    @ViewBuilder
    private var collapsedInfo: some View {
        if collapsedInfoEnabled {
            VStack(spacing: 0) {
                band {
                    // Hidden while the menu is up: the top bar shows the same title
                    // then, and two of them read as a duplicate.
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text.opacity(Self.collapsedInfoOpacity))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(showChrome ? 0 : 1)
                }

                Spacer(minLength: 0)

                band {
                    // Only while the menu is hidden. With the menu up the panel
                    // carries the page slider instead, and a floating label would
                    // sit underneath it.
                    if let label = chapterPageLabel, !showChrome {
                        Text(label)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(theme.text.opacity(Self.collapsedInfoOpacity))
                            .lineLimit(1)
                    }
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// One of the two reserved bands, sized like the hidden toolbar.
    private func band<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .padding(.horizontal, 24)
    }

    /// `current / total`, published by the paged reader.
    private var chapterPageLabel: String? {
        guard layout == .horizontal else { return nil }
        return pagedPageLabel
    }

    /// Page slider shown in the bottom band while the menu is open.
    ///
    /// Proportions follow Novella's `ReaderProgressSlider`: a 3pt track, a 12×18pt
    /// thumb on a 24pt touch area, and a 40pt band.
    @ViewBuilder
    private func pageSlider(current label: String) -> some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let total = max(pagedPageCount - 1, 1)
                let fraction = CGFloat(min(max(currentPageIndex, 0), total)) / CGFloat(total)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.text.opacity(0.15))
                        .frame(height: 3)
                    Capsule()
                        .fill(theme.text.opacity(0.45))
                        .frame(width: width * fraction, height: 3)
                    Capsule()
                        .fill(theme.text.opacity(0.75))
                        .frame(width: 18, height: 12)
                        .offset(x: max(0, width * fraction - 9))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = min(max(value.location.x / width, 0), 1)
                            requestedPage = Int((ratio * CGFloat(total)).rounded())
                        }
                )
            }
            .frame(height: 24)

            Text(label)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.text.opacity(Self.collapsedInfoOpacity))
        }
        .frame(height: 44)
        .padding(.horizontal, 24)
    }

    /// 0-based current page, derived from the `current / total` label.
    private var currentPageIndex: Int {
        guard let first = pagedPageLabel?.split(separator: "/").first,
              let page = Int(first.trimmingCharacters(in: .whitespaces)) else { return 0 }
        return max(page - 1, 0)
    }

    /// Top bar of the reader: back, chapter title, catalogue.
    ///
    /// Drawn here rather than in the navigation bar so it can appear and vanish
    /// with the control panel without touching the top safe area (see the note in
    /// `body`).
    /// Top bar of the reader: back, chapter title, catalogue.
    ///
    /// Drawn here rather than in the navigation bar so it can appear and vanish
    /// with the control panel without touching the top safe area (see the note in
    /// `body`). Each element is a Liquid Glass capsule, matching the floating panel
    /// at the bottom — no opaque bar, so the page keeps showing through and the two
    /// ends of the screen read as the same surface.
    private var topChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                glassIconButton("chevron.left", label: "返回") {
                    saveProgress()
                    dismiss()
                }

                Spacer(minLength: 0)

                Text(displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background { Color.clear.glassCapsule() }

                Spacer(minLength: 0)

                glassIconButton("list.bullet", label: "目录") {
                    showCatalog = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 0)
            .padding(.bottom, 4)
            // A soft gradient scrim behind the capsules. It fades into the page so
            // the bar does not read as an opaque slab, but still keeps the prose
            // from colliding with the buttons.
            .background {
                LinearGradient(
                    colors: [theme.background, theme.background.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            }

            Spacer(minLength: 0)
        }
    }

    /// A single glass capsule holding one icon, sized to match the panel buttons.
    private func glassIconButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.text)
                .frame(width: 40, height: 40)
                // The glass goes on a background layer rather than on the Button
                // itself: `glassEffect` on a Button replaces its rendering, which
                // made the icon (and the whole bar) disappear.
                .background { Color.clear.glassCapsule(interactive: true) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var chrome: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                if layout == .horizontal, pagedPageCount > 1 {
                    pageSlider(current: chapterPageLabel ?? "")
                }
                HStack(spacing: 14) {
                    Button {
                        Task { await model.goPrevious() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 40, height: 40)
                    }
                    .secondaryGlassButtonShape(capsule: false)
                    .disabled(!model.canGoPrevious)

                    Button {
                        showCatalog = true
                    } label: {
                        VStack(spacing: 1) {
                            Text("目录")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(model.index + 1)/\(model.chapters.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.text.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .secondaryGlassButtonShape(capsule: false)

                    Button {
                        Task { await model.goNext() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 40, height: 40)
                    }
                    .prominentGlassButtonShape()
                    .tint(theme.text)
                    .disabled(!model.canGoNext)
                }

                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size")
                            .font(.caption)
                        Slider(value: $fontSize, in: 14...28, step: 1)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "text.alignleft")
                            .font(.caption)
                        Slider(value: $lineSpacing, in: 2...16, step: 1)
                    }
                }
                // Theme-derived rather than `.secondary`: the panel sits on the
                // reader's own background, and the system colour stayed dark in
                // night mode and washed out in the paper theme.
                .foregroundStyle(theme.text.opacity(0.75))

                HStack(spacing: 8) {
                    // Page-turn mode and first-line indent live in Settings rather
                    // than here: changing either re-paginates the chapter, which
                    // loses the reading position and breaks the immersive flow.
                    Spacer()

                    ForEach(ReaderTheme.all, id: \.name) { item in
                        Button {
                            themeName = item.name
                        } label: {
                            Circle()
                                .fill(item.theme.background)
                                .overlay(Circle().strokeBorder(theme.text.opacity(0.22), lineWidth: 0.5))
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            themeName == item.name ? AppTheme.accent : .clear,
                                            lineWidth: 2
                                        )
                                )
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .glassCard(cornerRadius: 26)
            // No extra `.opacity` here: the glass material already lets the page
            // show through, and fading the whole panel made its own controls look
            // washed out — worst on the selected chips.
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .allowsHitTesting(true)
    }

    /// Compact toggle chip used inside the control panel.
    ///
    /// Selection is conveyed by the text/icon colour and a filled capsule rather
    /// than an extra stroke, so it matches the accent treatment used elsewhere.
    /// Compact icon-only toggle used inside the control panel.
    ///
    /// Colour comes from the reader theme rather than the accent: the panel sits
    /// on the reader's own background, and blue text there clashed with the rest of
    /// the bar. Selection is shown by a filled capsule and a stronger tint.
    private func readerChip(
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? theme.text : theme.text.opacity(0.55))
                .frame(width: 34, height: 28)
                .background {
                    Capsule().fill(
                        isOn ? theme.text.opacity(0.16) : theme.text.opacity(0.06)
                    )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func recordProgress() {
        guard let chapter = model.current else { return }
        store.record(novelID: novelID, chapterID: chapter.id, chapterTitle: chapter.title)
    }

    private func saveProgress() {
        recordProgress()
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Images

struct ZoomedImage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Inline illustration. The relay serves full-resolution scans (over 5000px
/// wide), so they are downsampled by the image loader and opened at full size in
/// `ImageViewer` when tapped.
struct ReaderImage: View {
    var url: URL
    var theme: ReaderTheme
    /// Set when the illustration was downloaded, so it renders without a network.
    var localURL: URL?

    @State private var failed = false

    /// A downloaded copy always wins over the remote URL.
    private var resolved: URL { localURL ?? url }

    var body: some View {
        Group {
            if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                    Text("插图加载失败")
                        .font(.caption)
                }
                .foregroundStyle(theme.text.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                AsyncImage(url: resolved, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    case .failure:
                        Color.clear.frame(height: 1).onAppear { failed = true }
                    case .empty:
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.text.opacity(0.08))
                            ProgressView().tint(theme.text)
                        }
                        .frame(height: 220)
                    @unknown default:
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Full-screen, zoomable illustration.
struct ImageViewer: View {
    var url: URL
    var theme: ReaderTheme
    var onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(lastScale * value, 1), 5)
                                }
                                .onEnded { _ in lastScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scale = scale > 1 ? 1 : 2.5
                                lastScale = scale
                            }
                        }
                case .failure:
                    Text("插图加载失败")
                        .foregroundStyle(.white.opacity(0.7))
                default:
                    ProgressView().tint(.white)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .padding()
                    }
                }
                Spacer()
                if scale > 1 {
                    Text("双指缩放，双击还原")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.bottom, 24)
                }
            }
        }
    }
}
