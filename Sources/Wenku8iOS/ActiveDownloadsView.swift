import SwiftUI
import Wenku8Core

/// The download in progress, with the same controls as the offline list.
///
/// It lives in Settings → 存储与数据 rather than on the book's page: a download keeps
/// running while the reader moves around, so a page that shows it only while open is the
/// wrong home for it.
struct ActiveDownloadsView: View {
    @StateObject private var manager = OfflineDownloadManager.shared
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        List {
            if manager.progress == nil, let starting = manager.startingNovelID {
                // The first request has not returned yet; say so rather than showing an
                // empty page, which looked like the tap had done nothing.
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在准备下载…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            manager.cancel()
                        } label: {
                            Image(systemName: "pause.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("取消下载")
                    }
                    .id(starting)
                }
            } else if let progress = manager.progress {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(progress.novelTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Text("\(progress.completed)/\(progress.total) 章")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                manager.cancel()
                            } label: {
                                Image(systemName: "pause.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("暂停下载")
                        }
                        ProgressView(value: progress.fraction)
                            .tint(AppTheme.accent)
                        Text(progress.currentChapterTitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("下载在后台继续，可以离开这个页面。")
                }
            } else {
                Section {
                    EmptyStateView(
                        symbol: "arrow.down.circle",
                        title: "没有正在下载的任务",
                        message: "在小说详情页的目录里选择要下载的分卷，进度会实时显示在这里。"
                    )
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("正在下载")
        .navigationBarTitleDisplayMode(.inline)
    }
}
