import SwiftUI
import Wenku8Core

/// The books whose metadata is cached, so the reader can see what is stored and drop it.
///
/// Metadata is kept separately from downloads: a book can be readable offline in every
/// sense except its chapters, and that still occupies space. Listing them makes the figure
/// in Settings actionable instead of a bare number.
struct MetadataCacheView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var entries: [OfflineStore.Entry] = []
    @State private var pendingDelete: OfflineStore.Entry?

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: "tray",
                        title: "还没有元数据缓存",
                        message: "书架上的书籍会自动缓存元数据，断网时也能看到书名、封面和简介。"
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
                    Text("共 \(entries.count) 本 · \(totalLabel)")
                }
            }
        }
        .navigationTitle("元数据缓存")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .alert("删除这本书的元数据？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete {
                    Task {
                        await OfflineStore.shared.delete(entry.novelID)
                        await refresh()
                    }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("删除后断网时将无法查看这本书的信息；下次进入书架会重新缓存。")
        }
    }

    private func row(_ entry: OfflineStore.Entry) -> some View {
        Button {
            router.open(.novel(entry.novelID))
        } label: {
            HStack(spacing: 12) {
                CoverCard(
                    url: entry.detail?.coverURL,
                    title: entry.title,
                    width: 40,
                    height: 56
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let author = entry.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(cachedSummary(entry))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What this entry actually holds: a description of its metadata, plus chapters when
    /// the book is also downloaded.
    private func cachedSummary(_ entry: OfflineStore.Entry) -> String {
        var parts: [String] = []
        if entry.detail != nil { parts.append("元数据") }
        if !entry.storedChapterIDs.isEmpty {
            parts.append("\(entry.storedChapterIDs.count) 章")
        }
        parts.append(formatBytes(entry.bytes))
        return parts.joined(separator: " · ")
    }

    private var totalLabel: String {
        formatBytes(entries.reduce(0) { $0 + $1.bytes })
    }

    private func refresh() async {
        // Metadata-only: a downloaded book has its own screen.
        entries = await OfflineStore.shared.entries()
            .filter { $0.detail != nil && $0.storedChapterIDs.isEmpty }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
