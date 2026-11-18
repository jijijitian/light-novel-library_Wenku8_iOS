import SwiftUI
import Wenku8Core

/// Left/right reading: the chapter is measured into pages and a horizontal swipe
/// moves one page at a time.
///
/// Swiping never changes the chapter by itself — only when the reader is already
/// on the last page of a chapter does "next" load the following chapter (and
/// symmetrically for "previous"), which is what every paged reader does. Chapter
/// navigation otherwise stays where it always was: the toolbar buttons, the
/// control bar's arrows, and the chapter list.
struct PagedReadingView: View {
    @ObservedObject var model: ReaderViewModel
    var theme: ReaderTheme
    var fontSize: Double
    var lineSpacing: Double
    var indent: CGFloat
    /// User-tunable breathing room, shared with the vertical mode.
    var topInset: Double
    var bottomInset: Double
    @Binding var showChrome: Bool
    /// Reports `current / total` upward so the collapsed band can display it.
    @Binding var pageLabel: String?
    /// Total pages in the current chapter, for the progress slider.
    @Binding var pageCount: Int
    /// 0-based page requested from outside (the slider); reset after applying.
    @Binding var requestedPage: Int?
    /// Set when the reader swipes past the final page of the final chapter.
    @State private var reachedBookEnd = false
    /// Where the *next* chapter load should land. Going forward starts at the first
    /// page; going back must land on the last page, and the chapter-change handler
    /// is what applies it (it runs after the content update, which reset to 0).
    @State private var landOnLastPage = false
    /// Suppresses the scroll animation for the jump that follows a chapter load.
    @State private var suppressScrollAnimation = false
    /// True while the reader itself is moving the scroll view, so its position
    /// reports are not treated as user turns.
    @State private var isProgrammaticScroll = false
    var onLongPressImage: (URL) -> Void

    @State private var pageIndex = 0
    @State private var pages: [ChapterPaginator.Page] = []
    @State private var measuredSize: CGSize = .zero

    /// Kept in one place so the paginator and the view agree on the text width.
    private static let horizontalPadding: CGFloat = 20
    /// No extra padding: `topInset` already carries the top-bar reservation from
    /// `ReaderView`, and adding more made paged mode start lower than scrolling.
    private static let topPadding: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            // `proxy` is already inset by the navigation bar and the status bar, so
            // adding `safeAreaInsets.top` here would double-count it and push the
            // first line far down the page. Only our own padding is added.
            let topPadding = CGFloat(topInset) + Self.topPadding
            let footerHeight: CGFloat = 0
            let size = CGSize(
                width: proxy.size.width - Self.horizontalPadding * 2,
                height: max(
                    80,
                    proxy.size.height - topPadding - footerHeight - resolvedBottomInset
                )
            )

            VStack(spacing: 0) {
                horizontalPager(size: size, topPadding: topPadding)

                // The page indicator is drawn by `ReaderView`'s collapsed band so it
                // stays visible with or without the menu; keeping a copy here made
                // it appear twice.
                Color.clear.frame(height: footerHeight)

                Spacer(minLength: 0)
            }
            .onChange(of: size.height) { _, _ in
                rebuild(size: size)
            }
            .onChange(of: model.index) { _, _ in
                // A different chapter is being fetched: drop the old pages now
                // rather than leaving them under the overlay.
                pages = []
            }
            .onChange(of: model.content?.chapterID) { _, _ in
                rebuild(size: size)
                // No animation: the pages were just replaced, so animating from the
                // old offset would read as an extra page turn after loading.
                pageIndex = landOnLastPage ? max(0, pages.count - 1) : 0
                landOnLastPage = false
                suppressScrollAnimation = true
                updatePageLabel()
            }
            .onChange(of: fontSize) { _, _ in rebuild(size: size) }
            .onChange(of: lineSpacing) { _, _ in rebuild(size: size) }
            .onChange(of: indent) { _, _ in rebuild(size: size) }
            // Keep the reported label in sync as pages turn; without this the label
            // stayed at its first value for the whole chapter.
            .onChange(of: pageIndex) { _, _ in updatePageLabel() }
            // Applies a page jump requested by the slider.
            .onChange(of: requestedPage) { _, newValue in
                guard let newValue, pages.indices.contains(newValue) else { return }
                pageIndex = newValue
                requestedPage = nil
            }
            .onChange(of: showChrome) { _, _ in updatePageLabel() }
            .onAppear { rebuild(size: size) }
        }
        .overlay {
            if model.isLoading {
                // Shown for every chapter change, not just the first one: the old
                // page must not linger while the next chapter is being fetched.
                loadingOverlay
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Text((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(theme.text.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await model.load() }
                    }
                    .prominentGlassButtonShape()
                    .tint(AppTheme.accent)
                }
                .padding(24)
            }
        }
        .overlay {
            if reachedBookEnd {
                bookEndNotice
            }
        }
    }

    /// Covers the previous page while the next chapter loads.
    ///
    /// Without it the old chapter stayed on screen until the new one arrived, which
    /// looked like the swipe had done nothing.
    private var loadingOverlay: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView().tint(theme.text)
                Text(model.current?.title ?? "正在载入…")
                    .font(.caption)
                    .foregroundStyle(theme.text.opacity(0.55))
                    .lineLimit(1)
                    .padding(.horizontal, 32)
            }
        }
        .transition(.opacity)
    }

    /// Shown when the reader swipes past the very last page of the book.
    private var bookEndNotice: some View {
        ZStack {
            theme.background.opacity(0.97)
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.text.opacity(0.55))
                Text("已经是最后一章了")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text.opacity(0.85))
                Text("全书已读完，感谢阅读")
                    .font(.caption)
                    .foregroundStyle(theme.text.opacity(0.5))
                Button("返回") {
                    reachedBookEnd = false
                }
                .prominentGlassButtonShape()
                .tint(AppTheme.accent)
                .padding(.top, 4)
            }
        }
        .transition(.opacity)
        .onTapGesture { reachedBookEnd = false }
    }

    /// Constant, so toggling the control panel never repaginates the chapter.
    private var resolvedBottomInset: CGFloat { CGFloat(bottomInset) }

    private func isTitleBlock(_ text: String, page: ChapterPaginator.Page) -> Bool {
        guard page.id == 0 else { return false }
        let title = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines) == title
    }

    /// Same type ramp as the vertical reader (`title3` bold), so a chapter looks
    /// identical in both modes. Built from the point size so no weight helper is
    /// needed.
    static let titleFont: UIFont = {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
        return UIFont.systemFont(ofSize: descriptor.pointSize, weight: .bold)
    }()

    @ViewBuilder
    private func pageContent(_ page: ChapterPaginator.Page) -> some View {
        VStack(alignment: .leading, spacing: ChapterPaginator.paragraphSpacing) {
            ForEach(Array(page.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    // The title is the first block of page one. It is drawn with the
                    // same ramp the vertical reader uses (`title3` bold) and keeps
                    // the indent prefix that the paginator measured with.
                    let isTitle = isTitleBlock(text, page: page)
                    Text(text)
                        .font(isTitle
                            ? Font(Self.titleFont)
                            : .system(size: fontSize))
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let url):
                    ReaderImage(url: url, theme: theme)
                        .onLongPressGesture(minimumDuration: 0.45) {
                            onLongPressImage(url)
                        }
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        // The tap layer needs the page's real width to know which third was hit.
        // It is read here rather than stored in `@State` from `body` (which mutated
        // state during layout and made the gesture unreliable).
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                handleTap(at: value.location, width: geo.size.width)
                            }
                    )
            }
        }
    }

    /// Routes a tap to a page turn or the menu, following Novella's proportions.
    private func handleTap(at location: CGPoint, width: CGFloat) {
        guard width > 0 else {
            withAnimation(.snappy(duration: 0.22)) { showChrome.toggle() }
            return
        }
        let ratio = location.x / width
        if ratio <= 0.3 {
            retreat()
        } else if ratio >= 0.7 {
            advance()
        } else {
            withAnimation(.snappy(duration: 0.22)) { showChrome.toggle() }
        }
    }

    /// Applies `.onScrollPhaseChange` on iOS 18+ and does nothing earlier.
    ///
    /// The property only exists from iOS 18, but the deployment target is 17. On 17
    /// the chapter boundary is still reachable through the drag gesture fallback.
    private struct ScrollSettleObserver: ViewModifier {
        var onSettle: () -> Void

        func body(content: Content) -> some View {
            if #available(iOS 18.0, *) {
                content.onScrollPhaseChange { oldPhase, newPhase in
                    guard newPhase == .idle,
                          oldPhase == .decelerating || oldPhase == .interacting else { return }
                    onSettle()
                }
            } else {
                content
            }
        }
    }

    /// Read-only view of the scroll position. Reporting back into it while the
    /// finger is down made the pager fight itself.
    private var pageScrollID: Binding<Int?> {
        Binding(
            get: { pageIndex },
            set: { newValue in
                guard let newValue, !isProgrammaticScroll else { return }
                // A settle at a neighbouring index is a normal turn.
                if newValue != pageIndex {
                    pageIndex = newValue
                }
            }
        )
    }

    /// Called once the scroll settles.
    ///
    /// Only keeps the reported page label in sync; chapter boundaries are handled by
    /// `advance`/`retreat`, which the drag gesture and the tap zones both call.
    private func handleScrollSettled(size: CGSize, topPadding: CGFloat) {
        updatePageLabel()
    }

    /// Horizontal pager built on a `ScrollView` rather than a paged `TabView`.
    ///
    /// A paged `TabView` eats horizontal drags, so a swipe at the last page simply
    /// bounced and the reader could not advance to the next chapter. With a
    /// `ScrollView` the drag is ours to interpret: crossing a page boundary moves
    /// the page, and dragging past either end steps to the neighbouring chapter.
    @ViewBuilder
    private func horizontalPager(size: CGSize, topPadding: CGFloat) -> some View {
        ScrollViewReader { readerProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        pageContent(page)
                            // Padding first, then a fixed frame of the pager's
                            // full width: the padding must live *inside* the page,
                            // otherwise each page is wider than the pager and
                            // `.paging` snaps to the wrong offset.
                            .padding(.horizontal, Self.horizontalPadding)
                            .padding(.top, topPadding)
                            .frame(width: size.width + Self.horizontalPadding * 2,
                                   height: topPadding + size.height,
                                   alignment: .topLeading)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            // Scroll position is *read*, never written back while the user drags:
            // a two-way binding here fought the scroll view and made paging
            // stutter. `.onScrollPhaseChange` gives us both the settled page and a
            // chance to react when the finger leaves at either end.
            .scrollPosition(id: pageScrollID)
            .frame(height: topPadding + size.height)
            // Boundary intent only: the scroll view owns the drag itself, so this
            // does not move anything. It reports a swipe that had nowhere to go,
            // which is how the reader reaches the neighbouring chapter.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard !isProgrammaticScroll else { return }
                        let dx = value.translation.width
                        guard abs(dx) > 50 else { return }
                        if dx < 0 { advance() } else { retreat() }
                    }
            )
            .modifier(ScrollSettleObserver {
                handleScrollSettled(size: size, topPadding: topPadding)
            })
            .onChange(of: pageIndex) { _, newValue in
                // Only the reader itself moves the scroll view here (slider jump,
                // chapter change). Turns driven by the user are already in place.
                guard isProgrammaticScroll else {
                    updatePageLabel()
                    return
                }
                if suppressScrollAnimation {
                    readerProxy.scrollTo(newValue, anchor: .leading)
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        readerProxy.scrollTo(newValue, anchor: .leading)
                    }
                }
                DispatchQueue.main.async {
                    isProgrammaticScroll = false
                    suppressScrollAnimation = false
                }
                updatePageLabel()
            }
        }
    }

    private var displayTitle: String {
        let fromRoute = model.current?.title ?? ""
        if !fromRoute.isEmpty { return fromRoute }
        return model.content?.title ?? ""
    }

    private func rebuild(size: CGSize) {
        guard let content = model.content else {
            pages = []
            return
        }
        measuredSize = size
        let built = ChapterPaginator.paginate(
            blocks: content.blocks,
            size: size,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            indent: indent,
            textColor: UIColor(theme.text),
            title: displayTitle,
            titleFont: Self.titleFont
        )
        pages = built
        if pageIndex >= built.count { pageIndex = max(0, built.count - 1) }
        updatePageLabel()
    }

    private func updatePageLabel() {
        guard !pages.isEmpty else {
            pageLabel = nil
            return
        }
        pageLabel = "\(pageIndex + 1) / \(pages.count)"
        pageCount = pages.count
    }

    /// One page forward; only at the end of the chapter does this load the next.
    private func advance() {
        if pageIndex + 1 < pages.count {
            withAnimation(.easeInOut(duration: 0.18)) { pageIndex += 1 }
        } else if model.canGoNext {
            // The chapter-change handler resets to page 0; nothing else to do here.
            landOnLastPage = false
            Task { await model.goNext() }
        } else {
            // Last page of the last chapter: tell the reader the book is finished
            // instead of swallowing the swipe.
            reachedBookEnd = true
        }
    }

    private func retreat() {
        if pageIndex > 0 {
            withAnimation(.easeInOut(duration: 0.18)) { pageIndex -= 1 }
        } else if model.canGoPrevious {
            // Ask the chapter-change handler to land on the last page. Doing the
            // jump here did not survive: that handler runs after `goPrevious()`
            // completes and used to reset the index to 0, which is why stepping
            // back always opened the previous chapter at its first page.
            landOnLastPage = true
            Task { await model.goPrevious() }
        }
    }
}
