import SwiftUI
import Wenku8Core

/// Chapter list for the reader.
struct CatalogSheet: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var scrolled = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            Task {
                                await model.jump(to: index)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(chapter.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if index == model.index {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .id(chapter.id)
                    }
                }
                .listStyle(.plain)
                // A book's catalogue runs to hundreds of chapters, and the list opened at its
                // beginning — so the chapter being read was usually nowhere on screen. It is
                // taken to the top once, on the first appearance; scrolling again would fight
                // the reader's own scrolling while the sheet is open.
                .onAppear {
                    guard !scrolled, let current = model.current else { return }
                    scrolled = true
                    proxy.scrollTo(current.id, anchor: .top)
                }
                .navigationTitle("章节目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
            }
        }
    }
}
