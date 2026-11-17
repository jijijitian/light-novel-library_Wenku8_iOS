import SwiftUI
import Wenku8Core

struct ShelfView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.saved.isEmpty {
                    EmptyStateView(
                        symbol: "books.vertical",
                        title: "书架还是空的",
                        message: "在小说详情页点击「加入书架」，就能在这里追踪阅读进度。",
                        actionTitle: "去首页看看"
                    ) {
                        router.tab = .home
                    }
                    .padding(.top, 30)
                } else {
                    HStack(spacing: 10) {
                        TagChip(text: "\(store.saved.count) 本收藏", systemImage: "bookmark.fill")
                        Spacer()
                    }
                    NovelGrid(novels: store.saved) { novel in
                        router.open(.novel(novel.id))
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 24)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "阅读进度", symbol: "timer")
                        ForEach(store.saved) { novel in
                            if let progress = store.progress(for: novel.id) {
                                Button {
                                    router.open(.novel(novel.id))
                                } label: {
                                    HStack(spacing: 12) {
                                        CoverCard(url: novel.coverURL, title: novel.title, width: 44, height: 62)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(novel.title)
                                                .font(.subheadline.weight(.semibold))
                                                .lineLimit(1)
                                            Text(progress.chapterTitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Text(relative(progress.updated))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 22)
                    .opacity(store.progress.isEmpty ? 0 : 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("我的书架")
        .toolbar {
            if !store.saved.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.saved) { novel in
                            Button(role: .destructive) {
                                store.remove(novel.id)
                            } label: {
                                Label(novel.title, systemImage: "minus.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
