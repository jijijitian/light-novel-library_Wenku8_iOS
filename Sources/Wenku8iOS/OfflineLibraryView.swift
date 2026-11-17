import SwiftUI
import Wenku8Core

/// Lists downloaded books, with per-book size, completion and deletion.
struct OfflineLibraryView: View {
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

            if manager.isDownloading, let progress = manager.progress {
                Section("正在下载") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(progress.currentTitle)
                            .font(.subheadline)
                            .lineLimit(1)
                        ProgressView(value: progress.fraction)
                            .tint(AppTheme.accent)
                        Text("\(progress.completed)/\(progress.total) 章")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: manager.progress) { _, newValue in
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let author = entry.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: entry.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(entry.isComplete ? .green : .secondary)
            }
            HStack(spacing: 8) {
                Text("\(entry.storedChapterIDs.count)/\(entry.chapterIDs.count) 章")
                Text("·")
                Text(formatBytes(entry.bytes))
                if !entry.isComplete {
                    Text("·")
                    Button("继续") {
                        manager.download(novelID: entry.novelID)
                    }
                    .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !entry.isComplete {
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
