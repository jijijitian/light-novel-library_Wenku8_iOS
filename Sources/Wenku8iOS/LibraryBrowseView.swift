import SwiftUI
import Wenku8Core

/// The libraries the site groups books into, as a list of destinations.
///
/// It used to be a row of chips above the search field, where it competed with searching;
/// browsing by library is a way in like the boards, so it is a screen of its own.
struct LibraryBrowseView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(
                        title: "按文库浏览",
                        subtitle: "点击文库查看其中的书",
                        symbol: "building.columns"
                    )
                    .padding(.bottom, 12)

                    // Grouped the way the ranking index groups its boards: a heading, then its
                    // rows in a `VStack` with a gap between them. Without that gap the libraries
                    // were a dense block while the ranking rows had air around them.
                    ForEach(Array(Self.grouped.enumerated()), id: \.offset) { _, group in
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.categories) { category in
                                Button {
                                    router.open(.library(category.id, category.name))
                                } label: {
                                    categoryRow(category)
                                }
                                .buttonStyle(.plain)
                                if category.id != group.categories.last?.id {
                                    Divider().opacity(0.35)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 22)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("文库")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The libraries, split the way the ranking index splits its boards: the one that shows
    /// everything first, then the individual libraries.
    private static var grouped: [(title: String, categories: [LibraryCategory])] {
        let all = LibraryCategory.all
        let everything = all.filter { $0.id == 0 }
        let rest = all.filter { $0.id != 0 }
        return [
            ("全部", everything),
            ("文库", rest),
        ].filter { !$0.1.isEmpty }
    }

    /// One library row, measured exactly like a row in the ranking index: same icon column,
    /// same text weight, same vertical padding. At the smaller values these used to carry, the
    /// two lists of the same kind of thing did not look alike.
    private func categoryRow(_ category: LibraryCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.subheadline)
                .frame(width: 26)
                .foregroundStyle(.tint)
            Text(category.name).font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
