import SwiftUI

/// How the reader turns pages.
public enum ReaderLayout: String, CaseIterable, Identifiable, Sendable {
    /// Vertical scrolling, the classic web-novel behaviour.
    case vertical
    /// Horizontal, one page at a time — the Android reader's left/right mode.
    case horizontal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vertical: return "上下滑动"
        case .horizontal: return "左右翻页"
        }
    }

    public var systemImage: String {
        switch self {
        case .vertical: return "arrow.up.arrow.down"
        case .horizontal: return "arrow.left.arrow.right"
        }
    }
}

/// Reading preferences shared by the reader and the settings screen.
///
/// Everything lives in `@AppStorage`-compatible keys so a value changed in one
/// place shows up in the other immediately.
enum ReaderPreferences {
    static let layoutKey = "reader.layout"
    static let indentKey = "reader.indentFirstLine"
    static let fontSizeKey = "reader.fontSize"
    static let lineSpacingKey = "reader.lineSpacing"
    static let themeKey = "reader.theme"
    /// Whether the faint title/page text is drawn while the menu is hidden.
    static let collapsedInfoKey = "reader.collapsedInfo"

    /// Chinese typesetting convention: the first line of a paragraph is indented
    /// by exactly two full-width characters.
    static func indent(for size: Double) -> CGFloat {
        CGFloat(size) * 2
    }
}

/// Layout constants shared by the reader's two modes.
enum ReaderMetrics {
    // MARK: - Breathing room around the prose
    //
    // Both values are user-tunable from Settings. The defaults were chosen by
    // looking at real pages on a 6.3" phone: 8pt above keeps the first line from
    // crowding the navigation bar, and 40pt below leaves the floating control
    // panel from covering the last visible line.

    static let topInsetKey = "reader.topInset"
    static let bottomInsetKey = "reader.bottomInset"

    static let defaultTopInset: Double = 4
    static let defaultBottomInset: Double = 12

    /// Range offered in Settings. The floor is 0 (text flush to the safe area)
    /// and the ceiling is generous enough to clear the control panel entirely.
    static let insetRange: ClosedRange<Double> = 0...80

    /// Opacity of the floating control panel, kept light so the text stays
    /// readable underneath it.
    static let chromeOpacity: Double = 0.82
}
