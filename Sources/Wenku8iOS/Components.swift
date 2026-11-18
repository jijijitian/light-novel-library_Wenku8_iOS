import SwiftUI
import Wenku8Core

struct NovelRow: View {
    var novel: NovelSummary
    var subtitle: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverCard(url: novel.coverURL, title: novel.title, width: 64, height: 90)
            VStack(alignment: .leading, spacing: 6) {
                Text(novel.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if let author = novel.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct NovelGridCell: View {
    var novel: NovelSummary
    var width: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverCard(url: novel.coverURL, title: novel.title, width: width, height: width * 1.42)
            Text(novel.title)
                .font(.caption)
                // Reserves two lines whether or not the title needs them, so a
                // one-line title does not make its cell shorter than a two-line one
                // and push the row out of alignment.
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }
}

struct NovelGrid: View {
    var novels: [NovelSummary]
    var onSelect: (NovelSummary) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(novels) { novel in
                Button {
                    onSelect(novel)
                } label: {
                    NovelGridCell(novel: novel)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct NovelList: View {
    var novels: [NovelSummary]
    var onSelect: (NovelSummary) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(novels) { novel in
                Button {
                    onSelect(novel)
                } label: {
                    NovelRow(novel: novel)
                }
                .buttonStyle(.plain)
                if novel.id != novels.last?.id {
                    Divider().opacity(0.4).padding(.leading, 76)
                }
            }
        }
    }
}
