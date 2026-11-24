import SwiftUI
import Wenku8Core

/// The app's settings, reached from 我的.
///
/// The tab that holds them is the reader's own page — account, statistics, and a way in here —
/// so the switches live behind one entry instead of leading the screen.
struct PreferencesView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("site.domain") private var domainRaw = SiteDomain.net.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var offlineCount = 0
    @State private var offlineBytes: Int64 = 0
    @State private var metadataCount = 0
    @State private var metadataBytes = "0 KB"
    @State private var showWeb = false
    @State private var showLicense = false

    var body: some View {
        Form {
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

            // Routed by value, not by a `NavigationLink` destination.
            //
            // A destination view builds its own stack entry that the router cannot see,
            // so opening a book from the list pushed onto the router's path while the
            // list sat outside it — returning landed on 设置 instead of the list.
            NavigationLink(value: AppRouter.Route.offlineLibrary) {
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
            NavigationLink(value: AppRouter.Route.metadataCache) {
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
        .task { await refreshOffline() }
        .sheet(isPresented: $showWeb) {
            WebSheet(url: SiteDomain.current.webURL("/"))
        }
        .sheet(isPresented: $showLicense) {
            LicenseSheet()
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
