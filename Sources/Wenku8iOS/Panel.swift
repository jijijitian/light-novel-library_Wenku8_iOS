import SwiftUI

/// A titled group of rows on a glass panel.
///
/// The app's other screens draw their content on `glassCard` surfaces; a `Form` cannot, because
/// the system draws its own background behind grouped rows. These pages therefore build their
/// groups from this panel so they read as the same material rather than as holes in it.
struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 22)
        }
    }
}

/// The vertical room a panel row takes.
///
/// Two numbers, not one: a row of labels wants room around its text, while a row carrying a cover
/// is as tall as the cover. Forcing both onto one value made the settings rows loose and the cache
/// rows tight.
enum PanelMetrics {
    /// Rows whose content is text and an icon — the settings and account screens.
    static let rowHeight: CGFloat = 50
    /// Rows carrying a cover thumbnail: the two cache screens. Taller than a labels row because
    /// the cover needs the room, and because these rows carry three lines of text.
    static let coverRowHeight: CGFloat = 72
}

/// One row inside a `Panel`: leading label, trailing value, consistent height.
struct PanelRow<Content: View>: View {
    @ViewBuilder var content: Content
    /// Vertical room a row takes. One number for every row in the app, so a screen that wants
    /// more or less says so at the call site rather than by copying the padding.
    var minHeight: CGFloat = PanelMetrics.rowHeight

    init(minHeight: CGFloat = PanelMetrics.rowHeight, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: minHeight)
        // Rows sit inside links, and a link tints its whole label; naming the colour here keeps
        // the text the ordinary label colour rather than the accent.
        .foregroundStyle(.primary)
        // A row inside a link would otherwise take the accent colour for its text and icons;
        // `tint` is what the link uses, so it is cleared here rather than at every call site.
        .tint(.primary)
        .contentShape(Rectangle())
    }
}

/// The disclosure indicator a link row shows.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: Self.width, alignment: .trailing)
    }

    /// The width every row reserves at its trailing edge, so a row without an indicator keeps
    /// its value in the same column as one that has it.
    static let width: CGFloat = 24
}

/// The space a row leaves where a link row would draw its chevron.
///
/// A plain row used to end at the panel's padding, which put its value a chevron's width to the
/// right of the value above it.
struct ChevronSpace: View {
    var body: some View {
        // A fixed frame on an empty view, not `Color.clear`: a clear colour has no intrinsic
        // width of its own and collapsed to nothing inside the row's `HStack`.
        Color.clear
            .frame(width: Chevron.width, height: 1)
            .layoutPriority(0)
    }
}

extension View {
    /// Gives a `Label`'s icon a fixed width.
    ///
    /// Two rows in a panel drew icons of different widths — `books.vertical` is wider than
    /// `book.pages` — so their titles started at different points and the list looked ragged.
    func labelIconFrame() -> some View {
        labelStyle(FixedWidthLabelStyle())
    }
}

private struct FixedWidthLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 22, alignment: .center)
            configuration.title
        }
    }
}
