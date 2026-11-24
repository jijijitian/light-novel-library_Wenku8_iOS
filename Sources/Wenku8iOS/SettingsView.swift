import SwiftUI
import Wenku8Core

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var router: AppRouter
    @State private var showLogin = false
    @State private var accountMessage: String?

    var body: some View {
        Form {
            profileSection

            accountSection

            // Shelf totals describe the reader's own library, so they sit here rather than
            // behind the settings entry.
            Section("书架") {
                LabeledContent {
                    Text("\(store.saved.count) 本").foregroundStyle(.secondary)
                } label: {
                    Label("已收藏", systemImage: "books.vertical")
                }
                NavigationLink {
                    ReadingProgressView()
                } label: {
                    LabeledContent {
                        Text("\(store.progress.count) 本").foregroundStyle(.secondary)
                    } label: {
                        Label("阅读进度", systemImage: "book.pages")
                    }
                }
            }

            Section {
                NavigationLink {
                    PreferencesView()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }

        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("我的")
        .task {
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
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
    }

    /// The version, shown under the profile block.
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// The header: who is signed in, and the app's own identity underneath.
    ///
    /// The screen is the reader's page rather than a settings list, so the account leads it and
    /// the switches follow. A signed-out reader gets a sign-in invitation in the same place.
    private var profileSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accent.opacity(0.16))
                    Image(systemName: account.isSignedIn
                          ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(AppTheme.accent)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.isSignedIn ? (account.userName ?? "已登录") : "未登录")
                        .font(.title3.weight(.semibold))
                    if account.isSignedIn {
                        Text("云端书架 \(account.remoteNovels.count) 本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("登录后可同步书架与阅读进度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if account.isSyncingShelf {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 6)

            // No manual sync row: the shelf syncs when the account signs in and whenever the
            // local shelf changes, so a button for it was a switch that did nothing a reader
            // could not already rely on.
            if !account.isSignedIn {
                Button {
                    showLogin = true
                } label: {
                    Label("登录文库账号", systemImage: "person.badge.key")
                }
            }
        } footer: {
            HStack {
                Text("轻小说文库 iOS 版")
                Spacer()
                Text(appVersion)
            }
            .font(.caption2)
        }
    }

    /// The signed-in account's details and actions.
    ///
    /// Who is signed in lives in the header above, so this holds only what the header does not:
    /// the most recent reading, and the two things a reader can do about the session.
    @ViewBuilder
    private var accountSection: some View {
        if account.isSignedIn {
            Section("文库账号") {
                if let latest = account.remoteShelf.compactMap(\.latestChapter).first {
                    LabeledContent {
                        Text(latest.title).lineLimit(1)
                    } label: {
                        Label("最近阅读", systemImage: "book.pages")
                    }
                }
                Button(role: .destructive) {
                    account.signOut()
                    accountMessage = "已退出登录"
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                if let accountMessage {
                    Text(accountMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
