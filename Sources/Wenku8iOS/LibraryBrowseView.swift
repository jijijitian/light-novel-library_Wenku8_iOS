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

                    ForEach(LibraryCategory.all) { category in
                        Button {
                            router.open(.library(category.id, category.name))
                        } label: {
                            categoryRow(category)
                        }
                        .buttonStyle(.plain)
                        if category.id != LibraryCategory.all.last?.id {
                            Divider().opacity(0.35)
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

    private func categoryRow(_ category: LibraryCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(category.name)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
