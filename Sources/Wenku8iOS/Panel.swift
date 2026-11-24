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
                    .foregroundStyle(.secondary)
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

/// One row inside a `Panel`: leading label, trailing value, consistent height.
struct PanelRow<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// The disclosure indicator a link row shows.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}
