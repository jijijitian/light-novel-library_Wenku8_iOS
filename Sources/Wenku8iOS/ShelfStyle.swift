import Foundation

/// How the shelf lays its books out.
///
/// The list draws a cover beside the title and the site's recorded chapter, so a shelf can be
/// read at a glance and each row says what was last read. The grid drops the chapter line for a
/// larger cover with the title beneath, which is how the home screen shows books and how a
/// reader browsing by cover prefers it.
enum ShelfStyle: String, CaseIterable, Identifiable, Sendable {
    case list
    case grid

    static let storageKey = "shelf.style"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表"
        case .grid: return "网格"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}
