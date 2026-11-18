import SwiftUI
import Wenku8Core

struct ShelfView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if account.isSignedIn {
                    cloudShelfSection
                }

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
        // Entering the page refreshes the cloud shelf, so the app and the website
        // agree on what is on it.
        .task { await account.syncShelf() }
        .refreshable { await account.syncShelf() }
        .toolbar {
            if !store.saved.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.saved) { novel in
                            Button(role: .destructive) {
                                store.remove(novel.id)
                                // Keep the website's shelf in step: the local list
                                // is only a mirror once the account is signed in.
                                if account.isSignedIn {
                                    Task { _ = await account.removeFromRemoteShelf(novel.id) }
                                }
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

    /// The site's shelf, grouped the way the website groups it.
    ///
    /// 默认书架 (classid 0) plus up to five extra shelves. The picker only appears
    /// when the account actually has more than one group, so a simple account is not
    /// shown a control with a single option.
    @ViewBuilder
    private var cloudShelfSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionHeader(title: "文库书架", symbol: "cloud")
                Spacer()
                if account.isSyncingShelf {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await account.syncShelf() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("刷新文库书架")
                }
            }

            if account.shelfGroups.count > 1 {
                Picker("书架分组", selection: Binding(
                    get: { account.selectedShelfClass },
                    set: { newValue in
                        Task { await account.selectShelfGroup(newValue) }
                    }
                )) {
                    ForEach(account.shelfGroups) { group in
                        Text(group.count > 0 ? "\(group.title)（\(group.count)）" : group.title)
                            .tag(group.classID)
                    }
                }
                .pickerStyle(.segmented)
            }

            if account.remoteShelf.isEmpty {
                Text(account.isSyncingShelf ? "正在同步…" : "这一组还没有书")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(account.remoteShelf) { entry in
                        Button {
                            router.open(.novel(entry.novel.id))
                        } label: {
                            cloudShelfRow(entry)
                        }
                        .buttonStyle(.plain)
                        if entry.id != account.remoteShelf.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 22)
    }

    /// One cloud-shelf row: cover, title, and the site's recorded latest chapter.
    private func cloudShelfRow(_ entry: ShelfEntry) -> some View {
        HStack(spacing: 12) {
            CoverCard(url: entry.novel.coverURL, title: entry.novel.title, width: 44, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.novel.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let author = entry.novel.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let chapter = entry.latestChapter {
                    Text(chapter.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
