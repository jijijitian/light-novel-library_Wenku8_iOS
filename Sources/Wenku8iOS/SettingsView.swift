import SwiftUI
import Wenku8Core

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                profileCard

                // Shelf totals describe the reader's own library, so they sit here rather than
                // behind the settings entry.
                Panel(title: "书架") {
                    PanelRow {
                        Label("已收藏", systemImage: "books.vertical")
                        Spacer(minLength: 0)
                        Text("\(store.saved.count) 本").foregroundStyle(.secondary)
                    }
                    Divider()
                    NavigationLink {
                        ReadingProgressView()
                    } label: {
                        PanelRow {
                            Label("阅读进度", systemImage: "book.pages")
                            Spacer(minLength: 0)
                            Text("\(store.progress.count) 本").foregroundStyle(.secondary)
                            Chevron()
                        }
                    }
                    .buttonStyle(.plain)
                }

                Panel {
                    // Routed by value like the screens behind it. A destination view builds a
                    // stack entry the router cannot see, so opening the cache lists from inside
                    // it pushed onto the router's path while the settings page sat outside it.
                    NavigationLink(value: AppRouter.Route.preferences) {
                        PanelRow {
                            Label("设置", systemImage: "gearshape")
                            Spacer(minLength: 0)
                            Chevron()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("我的")
        .task {
            // The identity comes from the stored copy, so it is on screen at once; the account
            // screen refreshes it.
            account.loadStoredProfile()
            #if DEBUG
            // `WENKU8_OPEN_DATA_SOURCE=1` opens 数据来源 on launch, so its connectivity
            // check can be looked at without driving the UI.
            if ProcessInfo.processInfo.environment["WENKU8_OPEN_DATA_SOURCE"] != nil {
                router.open(.dataSource)
            }
            if ProcessInfo.processInfo.environment["WENKU8_OPEN_METADATA"] != nil {
                router.open(.metadataCache)
            }
            #endif
        }
    }

    /// The header: who is signed in, and the app's own identity underneath.
    ///
    /// The screen is the reader's page rather than a settings list, so the account leads it and
    /// the switches follow. A signed-out reader gets a sign-in invitation in the same place.
    /// The header card: who is signed in, opening the account screen.
    private var profileCard: some View {
        NavigationLink {
            AccountView()
        } label: {
            HStack(spacing: 12) {
                AccountAvatar(url: account.profile?.avatarURL, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.isSignedIn ? (account.userName ?? "已登录") : "未登录")
                        .font(.headline)
                    if !account.isSignedIn {
                        Text("登录后可同步书架与阅读进度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if account.isSyncingShelf {
                    ProgressView().controlSize(.small)
                }
                Chevron()
            }
            .padding(14)
            .glassCard(cornerRadius: 22)
        }
        .buttonStyle(.plain)
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
