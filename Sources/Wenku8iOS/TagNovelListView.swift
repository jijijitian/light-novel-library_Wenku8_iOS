import SwiftUI
import Wenku8Core

/// A tag, and the four ways the site offers to look at its books.
///
/// The orderings used to be chips above the list, which meant switching one had to re-fetch
/// under the reader. They are entries here instead, the same shape as the board index: pick
/// one, and its list opens.
struct TagNovelListView: View {
    var tag: String

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(TagSort.allCases) { sort in
                    Button {
                        router.open(.tagList(tag, sort))
                    } label: {
                        row(sort)
                    }
                    .buttonStyle(.plain)
                    if sort != TagSort.allCases.last {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22)
            .padding(.top, 12)
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .background { AppBackground() }
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ sort: TagSort) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: sort))
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(sort.title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func symbol(for sort: TagSort) -> String {
        switch sort {
        case .updated: return "clock.arrow.circlepath"
        case .popular: return "flame"
        case .completed: return "checkmark.seal"
        case .anime: return "play.rectangle"
        }
    }
}
