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
                TabView(selection: $pageIndex) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        pageContent(page)
                            .frame(width: size.width, height: size.height, alignment: .topLeading)
                            .padding(.horizontal, Self.horizontalPadding)
                            .padding(.top, topPadding)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: topPadding + size.height)

                // The page indicator is drawn by `ReaderView`'s collapsed band so it
                // stays visible with or without the menu; keeping a copy here made
                // it appear twice.
                Color.clear.frame(height: footerHeight)

                Spacer(minLength: 0)
            }
            .onChange(of: size.height) { _, _ in
                rebuild(size: size)
            }
            .onChange(of: model.content?.chapterID) { _, _ in
                pageIndex = 0
                rebuild(size: size)
            }
            .onChange(of: fontSize) { _, _ in rebuild(size: size) }
            .onChange(of: lineSpacing) { _, _ in rebuild(size: size) }
            .onChange(of: indent) { _, _ in rebuild(size: size) }
            .onAppear { rebuild(size: size) }
        }
        .overlay {
            if model.isLoading && model.content == nil {
                ProgressView().tint(theme.text)
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
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) { showChrome.toggle() }
        }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width < -40 {
                        advance()
                    } else if value.translation.width > 40 {
                        retreat()
                    }
                }
        )
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
            pageIndex = 0
            Task { await model.goNext() }
        }
    }

    private func retreat() {
        if pageIndex > 0 {
            withAnimation(.easeInOut(duration: 0.18)) { pageIndex -= 1 }
        } else if model.canGoPrevious {
            // Opening the previous chapter should land on its last page, so the
            // flow reads continuously in both directions.
            Task {
                await model.goPrevious()
                if let content = model.content {
                    let built = ChapterPaginator.paginate(
                        blocks: content.blocks,
                        size: measuredSize,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        indent: indent,
                        textColor: UIColor(theme.text)
                    )
                    pages = built
                    pageIndex = max(0, built.count - 1)
                }
            }
        }
    }
}
