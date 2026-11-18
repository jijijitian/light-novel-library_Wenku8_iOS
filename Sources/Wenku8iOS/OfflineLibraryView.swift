import SwiftUI
import Wenku8Core

/// Lists downloaded books, with per-book size, completion and deletion.
struct OfflineLibraryView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var manager = OfflineDownloadManager.shared
    @State private var entries: [OfflineStore.Entry] = []
    @State private var totalBytes: Int64 = 0
    @State private var pendingDelete: OfflineStore.Entry?

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: "arrow.down.circle",
                        title: "还没有下载的小说",
                        message: "在小说详情页右上角的菜单里选择「下载到本机」，即可离线阅读。"
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                    .onDelete { offsets in
                        if let index = offsets.first { pendingDelete = entries[index] }
                    }
                } footer: {
                    Text("共 \(entries.count) 本 · \(formatBytes(totalBytes))")
                }
            }

        }
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: manager.progress) { _, newValue in
            // Refresh on every step, not just at the end: the row for the book being
            // downloaded was showing a stale chapter count for the whole download.
            Task { await refresh() }
            if newValue == nil { Task { await refresh() } }
        }
        .alert("删除本地缓存？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete {
                    Task {
                        await manager.delete(entry.novelID)
                        await refresh()
                    }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.title ?? "")
        }
    }

    private func row(_ entry: OfflineStore.Entry) -> some View {
        let live = manager.progress.flatMap { $0.novelID == entry.novelID ? $0 : nil }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        router.open(.novel(entry.novelID))
                    } label: {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    if let author = entry.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if live != nil {
                    Button {
                        manager.cancel()
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("暂停下载")
                } else if !entry.isComplete {
                    // Resume moved here, beside the pause it replaces, and sized to match.
                    Button {
                        manager.download(novelID: entry.novelID)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("继续下载")
                } else {
                    Image(systemName: entry.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(entry.isComplete ? .green : .secondary)
                }
            }
            HStack(spacing: 8) {
                // While downloading, report the live figure, so the row the reader is
                // watching actually advances.
                Text("\(live?.completed ?? entry.storedChapterIDs.count)/\(entry.chapterIDs.count) 章")
                Text("·")
                Text(formatBytes(entry.bytes))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let live {
                ProgressView(value: live.fraction)
                    .tint(AppTheme.accent)
                Text(live.currentChapterTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if !entry.isComplete {
                ProgressView(value: entry.progress)
                    .tint(AppTheme.accent)
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() async {
        entries = await OfflineStore.shared.entries()
        totalBytes = await OfflineStore.shared.totalBytes()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
