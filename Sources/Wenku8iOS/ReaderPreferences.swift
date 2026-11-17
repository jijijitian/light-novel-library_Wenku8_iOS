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

    /// Chinese typesetting convention: the first line of a paragraph is indented
    /// by exactly two full-width characters.
    static func indent(for size: Double) -> CGFloat {
        CGFloat(size) * 2
    }
}
