import SwiftUI
import UIKit

/// One-shot instruction to move to a page, identified so it is applied exactly once.
struct PagerJump: Equatable {
    let id: UUID
    let index: Int
    let animated: Bool
    /// True when the request comes from the page slider. Paging is suspended for
    /// those moves so UIKit does not emit its own per-boundary selection feedback.
    var fromSlider: Bool = false
}


/// Native horizontal pager backed by `UIScrollView`.
///
/// SwiftUI's `.offset` animation only produces as many frames as the state system
/// decides to hand out, which looked like a low-frame-rate slide; and juggling
/// `dragOffset` alongside a `@State` page index meant two sources of truth that
/// occasionally fought each other (the "vibration" felt on two-page chapters).
///
/// A `UIScrollView` does the same job the way Novella's reader does — Readium is a
/// WKWebView inside a scroll view — so the drag is driven by UIKit at display
/// refresh rate, deceleration is native, and there is exactly one owner of the
/// offset.
///
/// Pages are mounted through a single `UIHostingController` whose root view is a
/// `LazyHStack`; the scroll view only ever moves that one child, so paging stays
/// cheap regardless of chapter length.
struct NativePager<Page: View>: UIViewRepresentable {
    var pageCount: Int
    /// Page advances are reported back so the model keeps a single page index.
    @Binding var pageIndex: Int
    var pageWidth: CGFloat
    var pageHeight: CGFloat
    /// Called when the user drags past the first / last page.
    var onBoundary: (PagerBoundary) -> Void
    /// Taps are routed here with the x position inside the pager.
    var onTap: (CGFloat, CGFloat) -> Void
    /// An explicit page request coming from outside the pager (the slider). `nil`
    /// means "wherever the reader has scrolled to". Chapter loads are handled by the
    /// content rebuild below, so they do not need this.
    var jumpRequest: PagerJump?
    /// Bumped by the caller whenever the rendered text changes for a reason other
    /// than geometry (font size, line spacing, indentation). The hosted row is keyed
    /// on it so those updates actually redraw.
    var contentRevision: Int = 0
    var pageContent: (Int) -> Page

    enum PagerBoundary {
        case before
        case after
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        // Paging is toggled off while the page slider drives the offset: every
        // programmatic snap at a page boundary makes the system fire its own
        // "page settled" feedback, and a slider drag crosses that boundary many
        // times per second — which the user feels as the phone vibrating.
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        // Bouncing must stay on: the boundary check below reads an overscrolled
        // `contentOffset`, which cannot happen with bouncing disabled.
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        // One hosting controller renders every page side by side; the scroll view
        // moves it as a whole, so there is no per-page view churn.
        let host = UIHostingController(rootView: AnyView(pageRow()))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.frame = CGRect(
            x: 0,
            y: 0,
            width: pageWidth * CGFloat(max(pageCount, 1)),
            height: pageHeight
        )
        scrollView.addSubview(host.view)
        scrollView.contentSize = host.view.frame.size
        context.coordinator.host = host

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        scrollView.addGestureRecognizer(tap)
        // Without this the scroll view never calls back, so the page index stayed at
        // 0 (the label always read "1/N") and the edge callbacks that step to the
        // neighbouring chapter never ran.
        scrollView.delegate = context.coordinator

        context.coordinator.scrollView = scrollView
        context.coordinator.applyIndex(pageIndex, animated: false)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let expectedWidth = pageWidth * CGFloat(max(pageCount, 1))
        let key = Self.contentKey(
            pages: pageCount,
            width: expectedWidth,
            height: pageHeight,
            revision: contentRevision
        )
        let needsRebuild = coordinator.contentKey != key
        if needsRebuild {
            coordinator.contentKey = key
            coordinator.host?.rootView = AnyView(pageRow().frame(
                width: expectedWidth, height: pageHeight
            ))
            if let host = coordinator.host {
                host.view.frame = CGRect(x: 0, y: 0, width: expectedWidth, height: pageHeight)
                scrollView.contentSize = host.view.frame.size
            }
            // Pages were replaced (first load or chapter change): land on the
            // requested page without animating.
            coordinator.snap(to: pageIndex)
            return
        }

        // Never reposition the scroll view from here. `updateUIView` runs on any
        // SwiftUI invalidation — showing the menu, changing the theme — and writing
        // the offset then snapped the reader back to the page the model happened to
        // believe it was on. The scroll view is the source of truth for where the
        // reader is; explicit jumps (slider, chapter load) go through `move`/`snap`
        // from the code paths that actually intend them.
        // A slider jump is the one case where the pager must move itself.
        if let jump = jumpRequest, coordinator.lastAppliedJump != jump.id {
            coordinator.lastAppliedJump = jump.id
            coordinator.setPagingSuspended(jump.fromSlider)
            coordinator.move(to: jump.index, animated: jump.animated)
            if jump.fromSlider {
                // Restore paging once the slider settles, so normal swiping keeps
                // its snap-and-feedback behaviour.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak coordinator] in
                    coordinator?.setPagingSuspended(false)
                }
            }
        }
    }

    /// Cache key for the hosted row: content must be rebuilt when the number of
    /// pages changes, not only when the geometry does.
    static func contentKey(
        pages: Int,
        width: CGFloat,
        height: CGFloat,
        revision: Int
    ) -> String {
        "\(pages)|\(Int(width))|\(Int(height))|\(revision)"
    }

    private func pageRow() -> some View {
        HStack(spacing: 0) {
            ForEach(0..<max(pageCount, 1), id: \.self) { index in
                pageContent(index)
                    .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: NativePager
        weak var scrollView: UIScrollView?
        var host: UIHostingController<AnyView>?
        /// Identifies the currently hosted content so it is rebuilt on real changes.
        var contentKey: String?
        /// Id of the last `jumpRequest` applied, so repeated `updateUIView` calls do
        /// not re-apply the same jump.
        var lastAppliedJump: UUID?
        /// Set while we move the scroll view ourselves, so the delegate does not
        /// report our own motion as a user turn.
        private var isProgrammatic = false
        private var lastReportedIndex: Int?
        /// Set by `PagedReadingView` when the next index change should slide rather
        /// than snap (a slider jump animates; a tap or chapter load does not).
        var animateNextMove = false

        init(_ parent: NativePager) {
            self.parent = parent
            self.lastReportedIndex = parent.pageIndex
        }

        func offset(for index: Int) -> CGPoint {
            CGPoint(x: CGFloat(index) * parent.pageWidth, y: 0)
        }

        /// `animated: false` is used for taps and chapter loads: those must replace
        /// the page instantly rather than sliding.
        func applyIndex(_ index: Int, animated: Bool) {
            guard let scrollView, parent.pageWidth > 0 else { return }
            isProgrammatic = true
            let target = offset(for: index)
            if animated {
                UIView.animate(
                    withDuration: NativePager.transitionDuration,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
                ) {
                    scrollView.setContentOffset(target, animated: false)
                } completion: { _ in
                    self.isProgrammatic = false
                }
            } else {
                scrollView.setContentOffset(target, animated: false)
                isProgrammatic = false
            }
        }

        /// Suspends `.paging` while the slider drives the offset.
        ///
        /// `isPagingEnabled` makes UIKit emit its own selection feedback whenever
        /// the content settles on a page boundary. A slider drag crosses those
        /// boundaries continuously, so the feedback fired in a burst — the physical
        /// vibration. Paging is restored as soon as the drag finishes.
        func setPagingSuspended(_ suspended: Bool) {
            guard let scrollView else { return }
            scrollView.isPagingEnabled = !suspended
        }

        /// Jumps immediately — used when the pages themselves were just replaced.
        func snap(to index: Int) {
            guard let scrollView, parent.pageWidth > 0 else { return }
            isProgrammatic = true
            scrollView.setContentOffset(offset(for: index), animated: false)
            lastReportedIndex = index
            // `setContentOffset` notifies the delegate synchronously in some cases,
            // so the flag is cleared on the next run loop — otherwise `didScroll`
            // would treat our own jump as a user turn and write back an index that
            // may already be stale.
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammatic = false
            }
        }

        /// Slides to a page over a fixed duration.
        func move(to index: Int, animated: Bool) {
            guard let scrollView, parent.pageWidth > 0 else { return }
            let target = offset(for: index)
            // A new move must supersede any move still in flight. Without this the
            // previous animation's completion fires late and clears
            // `isProgrammatic` while the newer one is still running, which lets the
            // delegate treat our own scroll as a user turn.
            scrollView.layer.removeAllAnimations()
            if animated {
                isProgrammatic = true
                UIView.animate(
                    withDuration: NativePager.transitionDuration,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
                ) {
                    scrollView.setContentOffset(target, animated: false)
                } completion: { _ in
                    self.isProgrammatic = false
                }
            } else {
                snap(to: index)
            }
            lastReportedIndex = index
        }

        func currentPage(_ scrollView: UIScrollView) -> Int {
            guard parent.pageWidth > 0 else { return 0 }
            let raw = scrollView.contentOffset.x / parent.pageWidth
            return min(max(Int(raw.rounded()), 0), max(parent.pageCount - 1, 0))
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammatic else { return }
            let page = currentPage(scrollView)
            guard page != lastReportedIndex else { return }
            lastReportedIndex = page
            if parent.pageIndex != page {
                parent.pageIndex = page
            }
        }

        /// A drag released at either edge steps to the neighbouring chapter.
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
            guard !isProgrammatic else { return }
            let page = currentPage(scrollView)
            let atFirst = page == 0
            let atLast = page == max(parent.pageCount - 1, 0)
            let pull = scrollView.contentOffset.x - CGFloat(page) * parent.pageWidth
            // A drag that moved the content backwards at the first page, or forwards
            // at the last one, is a request for the neighbouring chapter.
            if atFirst && pull < -24 {
                parent.onBoundary(.before)
            } else if atLast && pull > 24 {
                parent.onBoundary(.after)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            syncIndex(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammatic = false
            syncIndex(scrollView)
        }

        private func syncIndex(_ scrollView: UIScrollView) {
            let page = currentPage(scrollView)
            lastReportedIndex = page
            if parent.pageIndex != page { parent.pageIndex = page }
        }

        // MARK: Tap

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            // `location(in: scrollView)` is in *content* coordinates and therefore
            // includes `contentOffset`. From page two on that offset is a whole page
            // wide, which pushed every tap into the "next page" third — the reason
            // only page one behaved. Subtracting it yields the position inside the
            // visible frame.
            let inContent = gesture.location(in: scrollView)
            let x = inContent.x - scrollView.contentOffset.x
            parent.onTap(x, scrollView.bounds.width)
        }

        /// The tap must not fire once the finger has started a drag, or a swipe
        /// would also register as a page tap.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// Fixed slide duration, matching the previous SwiftUI value.
    static var transitionDuration: TimeInterval { 0.22 }
}
