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

    @AppStorage(ReaderPreferences.themeKey) private var themeName = "纸白"
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = 18.0
    @AppStorage(ReaderPreferences.lineSpacingKey) private var lineSpacing = 8.0
    @AppStorage(ReaderPreferences.layoutKey) private var layoutRaw = ReaderLayout.vertical.rawValue
    @AppStorage(ReaderPreferences.indentKey) private var indentFirstLine = false

    init(novelID: Int, chapters: [ChapterLink], startIndex: Int) {
        self.novelID = novelID
        self.chapters = chapters
        self.startIndex = startIndex
        _model = StateObject(
            wrappedValue: ReaderViewModel(novelID: novelID, chapters: chapters, startIndex: startIndex)
        )
    }

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
                    showChrome: $showChrome,
                    onLongPressImage: { zoomedImage = ZoomedImage(url: $0) }
                )
            }

            if showChrome {
                chrome
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .navigationBarBackButtonHidden(true)
        // The navigation bar stays visible on purpose. Toggling it with the control
        // panel changed the top safe area, which shifted and resized the prose on
        // every tap — the "text gets shorter" bug. Only the panel itself (which
        // floats over the content) reacts to `showChrome` now.
        .toolbar(.visible, for: .navigationBar)
        // Reading is a full-screen mode: the tab bar must not sit under the text,
        // otherwise it steals vertical space and clashes with the reader's own
        // glass control bar.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    saveProgress()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .principal) {
                Text(displayTitle)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCatalog = true
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
        }
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
            VStack(alignment: .leading, spacing: 20) {
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
            .padding(.top, 24)
            // The control panel floats *over* the prose: the bottom inset is
            // constant so showing or hiding it never reflows the text.
            .padding(.bottom, ReaderMetrics.bottomInset)
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
        Text(displayTitle)
            .font(.title3.weight(.bold))
            .foregroundStyle(theme.text)
            .fixedSize(horizontal: false, vertical: true)
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
                Text(text)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // Chinese typesetting indents the first line by two
                    // full-width characters rather than using a tab stop.
                    .padding(.leading, indentFirstLine ? ReaderPreferences.indent(for: fontSize) : 0)
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

    private var chrome: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
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
                                .font(.caption.weight(.semibold))
                            Text("\(model.index + 1)/\(model.chapters.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                    .tint(AppTheme.accent)
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
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    // Layout and indentation are the two newest switches, so they
                    // sit with the other inline controls for quick access.
                    Button {
                        layoutRaw = (layout == .vertical
                            ? ReaderLayout.horizontal
                            : ReaderLayout.vertical).rawValue
                    } label: {
                        Label(layout.title, systemImage: layout.systemImage)
                            .font(.caption)
                            .labelStyle(.iconOnly)
                            .frame(width: 30, height: 26)
                    }
                    .secondaryGlassButtonShape(capsule: false)

                    Button {
                        indentFirstLine.toggle()
                    } label: {
                        Image(systemName: "text.append")
                            .font(.caption)
                            .frame(width: 30, height: 26)
                    }
                    .secondaryGlassButtonShape(capsule: false)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(indentFirstLine ? AppTheme.accent : .clear, lineWidth: 2)
                    )

                    Spacer()

                    ForEach(ReaderTheme.all, id: \.name) { item in
                        Button {
                            themeName = item.name
                        } label: {
                            Circle()
                                .fill(item.theme.background)
                                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
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
            // Light enough that the prose stays legible through the panel, which
            // is now an overlay rather than something the layout makes room for.
            .opacity(ReaderMetrics.chromeOpacity)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .allowsHitTesting(true)
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
