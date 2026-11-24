import SwiftUI
import Wenku8Core

/// Every book with a recorded reading position, most recently read first.
///
/// It used to sit at the bottom of the shelf, where it competed with the shelf itself — the
/// list of books someone keeps is not the same list as the ones they are partway through. It is
/// reached from 我的 instead, which is where the rest of the reader's own state lives.
struct ReadingProgressView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var store: LibraryStore

    private var novels: [NovelSummary] {
        let source = account.isSignedIn ? account.remoteShelf.map(\.novel) : store.saved
        return source
            .filter { store.progress(for: $0.id) != nil }
            .sorted {
                (store.progress(for: $0.id)?.updated ?? .distantPast)
                    > (store.progress(for: $1.id)?.updated ?? .distantPast)
            }
    }

    var body: some View {
        ScrollView {
            if novels.isEmpty {
                EmptyStateView(
                    symbol: "timer",
                    title: "还没有阅读记录",
                    message: "打开一本书开始阅读，进度会记录在这里。"
                )
                .padding(.top, 40)
            } else {
                VStack(spacing: 10) {
                    ForEach(novels) { novel in
                        row(novel)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .background { AppBackground() }
        .navigationTitle("阅读进度")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ novel: NovelSummary) -> some View {
        Button {
            router.open(.novel(novel.id))
        } label: {
            HStack(spacing: 12) {
                CoverCard(url: novel.coverURL, title: novel.title, width: 44, height: 62)
                VStack(alignment: .leading, spacing: 3) {
                    Text(novel.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let progress = store.progress(for: novel.id) {
                        Text(progress.chapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(relative(progress.updated))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .glassCard(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
