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
    var paragraphSpacing: Double
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
    var onLongPressImage: (URL) -> Void
    /// Leaves the reader, used by the end-of-book screen.
    var onClose: () -> Void

    /// One-shot instruction for the native pager (slider jumps only).
    @State private var jumpRequest: PagerJump?
    /// Bumped whenever the rendered text changes without changing the page count
    /// (font size, line spacing, indent), so the hosted row redraws.
    @State private var contentRevision = 0
    @State private var pageIndex = 0
    @State private var pages: [ChapterPaginator.Page] = []
    @State private var measuredSize: CGSize = .zero

    /// Kept in one place so the paginator and the view agree on the text width.
    private static let horizontalPadding: CGFloat = 20
    /// No extra padding: `topInset` already carries the top-bar reservation from
    /// `ReaderView`, and adding more made paged mode start lower than scrolling.
    private static let topPadding: CGFloat = 0

    /// Fixed duration for a swipe-driven page slide.
    private static let turnDuration: Double = 0.22

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
                updatePageLabel()
            }
            .onChange(of: fontSize) { _, _ in
                rebuild(size: size)
                contentRevision += 1
            }
            .onChange(of: lineSpacing) { _, _ in
                rebuild(size: size)
                contentRevision += 1
            }
            .onChange(of: paragraphSpacing) { _, _ in
                rebuild(size: size)
                contentRevision += 1
            }
            .onChange(of: theme) { _, _ in
                // Colours changed but the pagination did not: bump the revision so
                // the hosted row redraws with the new text colour.
                contentRevision += 1
            }
            .onChange(of: indent) { _, _ in
                rebuild(size: size)
                contentRevision += 1
            }
            // Keep the reported label in sync as pages turn; without this the label
            // stayed at its first value for the whole chapter.
            .onChange(of: pageIndex) { _, _ in updatePageLabel() }
            // Applies a page jump requested by the slider.
            .onChange(of: requestedPage) { _, newValue in
                guard let newValue, pages.indices.contains(newValue) else { return }
                // Slider jumps glide. `fromSlider` suspends paging for the duration
                // so UIKit does not add its own per-boundary feedback on top.
                jumpRequest = PagerJump(id: UUID(), index: newValue, animated: true, fromSlider: true)
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
                // The overlay must not swallow taps: the reader still wants to be
                // able to summon the menu while a chapter is loading.
                loadingOverlay
                    .allowsHitTesting(false)
                    // With the pages cleared there is nothing under the overlay to
                    // carry a tap, so one is layered on top: loading must still let
                    // the reader summon the menu.
                    .overlay { loadingTapLayer }
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
    /// Invisible tap catcher used while a chapter loads.
    ///
    /// Mirrors the pager's own routing so the loading state behaves like a loaded
    /// page: the middle opens the menu, the sides would turn a page (which the model
    /// ignores while loading).
    private var loadingTapLayer: some View {
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
    /// Shown when the reader tries to go past the last page of the book.
    ///
    /// Full-screen and fully opaque: at 0.97 the prose underneath stayed faintly
    /// visible, which read as a rendering bug rather than a deliberate screen. Only
    /// the left third steps back (to the last page), the middle and right thirds do
    /// nothing, and the button returns to the shelf.
    private var bookEndNotice: some View {
        GeometryReader { geo in
            ZStack {
                // Opaque, not translucent: nothing of the previous page may show.
                theme.background
                    .ignoresSafeArea()

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

                    Button {
                        onClose()
                    } label: {
                        Text("返回书架")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .prominentGlassButtonShape()
                    .tint(AppTheme.accent)
                    .padding(.top, 6)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        // Only the left third leaves this screen, matching the
                        // page-turn zones: here it steps back to the last page
                        // instead of turning forward.
                        if value.location.x <= geo.size.width * 0.3 {
                            reachedBookEnd = false
                        }
                    }
            )
        }
        .transition(.opacity)
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
        VStack(alignment: .leading, spacing: paragraphSpacing) {
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
        // Taps are handled once, by the pager, so they are not swallowed by each
        // page's own gesture.
        .contentShape(Rectangle())
    }

    private func horizontalPager(size: CGSize, topPadding: CGFloat) -> some View {
        let pageWidth = size.width + Self.horizontalPadding * 2
        let height = topPadding + size.height
        return NativePager(
            pageCount: pages.count,
            pageIndex: $pageIndex,
            pageWidth: pageWidth,
            pageHeight: height,
            onBoundary: { boundary in
                switch boundary {
                case .before: retreatChapter()
                case .after: advanceChapter()
                }
            },
            onTap: { x, width in
                handleTap(at: CGPoint(x: x, y: 0), width: width)
            },
            jumpRequest: jumpRequest,
            contentRevision: contentRevision
        ) { index in
            // `@ViewBuilder` inside the closure is not inferred across the
            // representable boundary, so the branch is spelled out as one type.
            pageSlot(at: index)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, topPadding)
        }
        .frame(width: pageWidth, height: height)
    }

    /// One page, or an empty placeholder while pages are being rebuilt.
    @ViewBuilder
    private func pageSlot(at index: Int) -> some View {
        if pages.indices.contains(index) {
            pageContent(pages[index])
        } else {
            Color.clear
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
            paragraphSpacing: paragraphSpacing,
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

    /// Tap in the outer thirds: turn the page instantly, or close the menu.
    ///
    /// A tap never animates — the reader should feel like a page was replaced, not
    /// like it slid. When the menu is open a side tap is treated as "dismiss" so it
    /// cannot be mistaken for a page turn.
    private func handleTap(at location: CGPoint, width: CGFloat) {
        guard width > 0 else { return }
        let ratio = location.x / width
        let isSideTap = ratio <= 0.3 || ratio >= 0.7

        if showChrome {
            // Any tap while the menu is up only closes it, matching Novella.
            withAnimation(.snappy(duration: 0.22)) { showChrome = false }
            return
        }

        guard isSideTap else {
            withAnimation(.snappy(duration: 0.22)) { showChrome = true }
            return
        }

        // Taps never animate: `NativePager` snaps the offset, so the next page is
        // simply there.
        if ratio <= 0.3 {
            retreat()
        } else {
            advance()
        }
    }

    /// The native pager reports a drag past the last page.
    private func advanceChapter() {
        guard model.canGoNext else {
            reachedBookEnd = true
            return
        }
        landOnLastPage = false
        Task { await model.goNext() }
    }

    /// The native pager reports a drag past the first page.
    private func retreatChapter() {
        guard model.canGoPrevious else { return }
        landOnLastPage = true
        Task { await model.goPrevious() }
    }

    /// One page forward; only at the end of the chapter does this load the next.
    private func advance() {
        // A chapter is already being fetched: a side tap would otherwise queue a
        // second request for the same chapter.
        guard !model.isLoading else { return }
        if pageIndex + 1 < pages.count {
            let target = pageIndex + 1
            // The scroll view owns the offset now, so the index alone is not enough:
            // a jump request is what actually moves the page. Taps snap (no
            // animation), which is why `animated: false`.
            jumpRequest = PagerJump(id: UUID(), index: target, animated: false)
            pageIndex = target
            updatePageLabel()
        } else if model.canGoNext {
            landOnLastPage = false
            Task { await model.goNext() }
        } else {
            reachedBookEnd = true
        }
    }

    private func retreat() {
        guard !model.isLoading else { return }
        if pageIndex > 0 {
            let target = pageIndex - 1
            jumpRequest = PagerJump(id: UUID(), index: target, animated: false)
            pageIndex = target
            updatePageLabel()
        } else if model.canGoPrevious {
            landOnLastPage = true
            Task { await model.goPrevious() }
        }
    }
}
