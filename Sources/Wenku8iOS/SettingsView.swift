import SwiftUI
import Wenku8Core

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var account: AccountStore
    @State private var showWeb = false
    @State private var showLicense = false
    @State private var showLogin = false
    @State private var accountMessage: String?
    @AppStorage("site.domain") private var domainRaw = SiteDomain.net.rawValue
    @State private var offlineCount = 0
    @State private var offlineBytes: Int64 = 0
    @State private var metadataCount = 0
    @State private var metadataBytes = "0 KB"
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill")
                        .font(.title2)
                        .frame(width: 48, height: 48)
                       .glassCard(cornerRadius: 14, tint: AppTheme.accent.opacity(0.4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("轻小说文库").font(.headline)
                        Text("iOS 版 · SwiftUI + Liquid Glass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            accountSection

            // Two-level menu: the front page is a directory of sub-screens, so each
            // group of related options has room to breathe instead of one long form.
            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    LabeledContent {
                        Text(appearanceTitle)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                }

                NavigationLink {
                    ReaderSettingsView()
                } label: {
                    LabeledContent {
                        Text(readerSummary)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("阅读", systemImage: "book")
                    }
                }
            }

            Section {
                // An active transfer first: it is the thing that is happening now, and it
                // used to share an icon with the storage row below it, which made the two
                // hard to tell apart.
                NavigationLink {
                    ActiveDownloadsView()
                } label: {
                    LabeledContent {
                        Text(downloadSummary)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("正在下载", systemImage: "arrow.down.circle.fill")
                    }
                }

                NavigationLink {
                    OfflineLibraryView()
                } label: {
                    LabeledContent {
                        Text(offlineSummary)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("离线缓存", systemImage: "internaldrive")
                    }
                }

                // Metadata is cached separately from downloads, so it gets its own row:
                // a reader can tell what the app holds offline even with nothing
                // downloaded. It opens the list, because a bare count is not actionable.
                NavigationLink {
                    MetadataCacheView()
                } label: {
                    LabeledContent {
                        Text(metadataSummary)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("元数据缓存", systemImage: "tray.full")
                    }
                }

                NavigationLink {
                    DataSourceSettingsView()
                } label: {
                    LabeledContent {
                        Text(domainTitle)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("数据来源", systemImage: "globe.asia.australia")
                    }
                }
            } header: {
                Text("存储与数据")
            }

            Section("书架") {
                LabeledContent("已收藏", value: "\(store.saved.count) 本")
                LabeledContent("阅读进度", value: "\(store.progress.count) 本")
                Button(role: .destructive) {
                    store.clearHistory()
                } label: {
                    Label("清空搜索历史", systemImage: "trash")
                }
            }

            Section {
                NavigationLink {
                    AboutSettingsView(onShowLicense: { showLicense = true })
                } label: {
                    LabeledContent {
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }

                Button {
                    showWeb = true
                } label: {
                    Label("打开文库网页版", systemImage: "safari")
                }
            } header: {
                Text("关于")
            } footer: {
                Text("本应用为非官方第三方客户端，所有内容均来自轻小说文库网站，仅供学习交流使用。")
                    .font(.footnote)
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("设置")
        .sheet(isPresented: $showWeb) {
            WebSheet(url: SiteDomain.current.webURL("/"))
        }
        .sheet(isPresented: $showLicense) {
            LicenseSheet()
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .task { await refreshOffline() }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("文库账号") {
            if account.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.userName ?? "已登录").font(.subheadline.weight(.semibold))
                        Text("已同步云端书架 \(account.remoteNovels.count) 本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let latest = account.remoteShelf.compactMap(\.latestChapter).first {
                            Text("最近阅读：\(latest.title)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if account.isSyncingShelf {
                        ProgressView().controlSize(.small)
                    }
                }
                Button {
                    Task {
                        await account.syncShelf()
                        accountMessage = "已同步云端书架"
                    }
                } label: {
                    Label("立即同步书架", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) {
                    account.signOut()
                    accountMessage = "已退出登录"
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    Label("登录文库账号", systemImage: "person.badge.key")
                }
                Text("登录后可把小说加入文库云端书架，并在多台设备间同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let accountMessage {
                Text(accountMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceTitle: String {
        (AppAppearance(rawValue: appearanceRaw) ?? .system).title
    }

    /// Compact summary of the reading settings, shown on the row that opens them.
    /// Read straight from storage: these values now live in `ReaderSettingsView`.
    private var readerSummary: String {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: ReaderPreferences.layoutKey)
            ?? ReaderLayout.vertical.rawValue
        let layout = ReaderLayout(rawValue: raw) ?? .vertical
        let stored = defaults.double(forKey: ReaderPreferences.fontSizeKey)
        let size = stored > 0 ? stored : ReaderPreferences.defaultFontSize
        return "\(layout.title) · \(Int(size))pt"
    }

    private var domainTitle: String {
        (SiteDomain(rawValue: domainRaw) ?? .net).title
    }

    /// Books whose metadata is cached without any downloaded chapter.
    private var metadataSummary: String {
        guard metadataCount > 0 else { return "未缓存" }
        return "\(metadataCount) 本 · \(metadataBytes)"
    }

    /// Current download state, shown on the row that opens it.
    private var downloadSummary: String {
        guard let progress = OfflineDownloadManager.shared.progress else { return "无任务" }
        return "\(progress.completed)/\(progress.total) 章"
    }

    private var offlineSummary: String {
        offlineCount == 0 ? "未下载" : "\(offlineCount) 本 · \(formatBytes(offlineBytes))"
    }

    private func refreshOffline() async {
        // Two separate tallies: what can be read offline, and what is only described.
        let downloaded = await OfflineStore.shared.downloadedEntries()
        offlineCount = downloaded.count
        // Only the downloaded books' own bytes, so this figure does not silently include
        // the metadata cache reported on the row below.
        offlineBytes = downloaded.reduce(0) { $0 + $1.bytes }

        let all = await OfflineStore.shared.entries()
        let metadataOnly = all.filter { $0.detail != nil && !$0.hasDownloadedChapters }
        metadataCount = metadataOnly.count
        metadataBytes = formatBytes(metadataOnly.reduce(0) { $0 + $1.bytes })
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("轻小说文库 iOS 版").font(.title3.weight(.bold))
                    Text("""
                    本项目是 MewX 的《轻小说文库 Android 版》的 iOS 重制版本，\
                    以 SwiftUI 重写界面，使用 Xcode 构建。

                    数据全部来自轻小说文库（wenku8.net）公开网页，仅供学习交流。\
                    应用不存储、不转售任何作品内容，所有版权归原作者与出版机构所有。
                    """)
                    .font(.subheadline)
                    Text("原始项目：MewX/light-novel-library_Wenku8_Android（GPL-2.0）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("界面参考了 Android 版的信息结构与功能划分，代码为独立实现。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { AppBackground() }
            .navigationTitle("开源声明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
