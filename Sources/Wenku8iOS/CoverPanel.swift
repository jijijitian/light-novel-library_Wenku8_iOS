import SwiftUI
import Wenku8Core

/// A titled panel of books, as the explore screen shows them: a heading, a horizontal row of
/// covers, and the option to open the row into a grid or to continue to the full list.
///
/// Shared by the website's homepage panels and the heat ranking, which are the same thing to
/// a reader — a named shelf of books.
struct CoverPanel: View {
    var title: String
    var novels: [NovelSummary]
    var symbol: String = "sparkles"
    /// The site's own 「更多」 destination, when it gives the panel one.
    var more: (() -> Void)?
    var onSelect: (Int) -> Void

    @State private var expanded = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: title, symbol: symbol)
                if let more {
                    Button(action: more) {
                        Text("更多")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                if novels.count > 4 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "收起" : "展开全部")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }

            if expanded {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(novels) { novel in
                        cell(novel)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(novels) { novel in
                            cell(novel)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func cell(_ novel: NovelSummary) -> some View {
        Button {
            onSelect(novel.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverCard(url: novel.coverURL, title: novel.title, width: 88, height: 124)
                Text(novel.title)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 88, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
