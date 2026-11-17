import SwiftUI
import Wenku8Core

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var account: AccountStore
    @State private var showWeb = false
    @State private var showLicense = false
    @State private var showLogin = false
    @State private var accountMessage: String?
    @State private var relayEnabled = RelayCredentialStore.shared.isEnabled
    private let relayStore = RelayCredentialStore.shared
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0

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

            Section("阅读") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("字号", systemImage: "textformat.size")
                        Spacer()
                        Text("\(Int(fontSize)) pt").foregroundStyle(.secondary)
                    }
                    Slider(value: $fontSize, in: 14...28, step: 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("行距", systemImage: "text.alignleft")
                        Spacer()
                        Text("\(Int(lineSpacing))").foregroundStyle(.secondary)
                    }
                    Slider(value: $lineSpacing, in: 2...16, step: 1)
                }
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

            Section("数据来源") {
                Button {
                    showWeb = true
                } label: {
                    Label("打开文库网页版", systemImage: "safari")
                }
                Link(destination: URL(string: "https://wenku8.mewx.org/")!) {
                    Label("项目主页", systemImage: "globe")
                }
            }

            relaySection

            Section("关于") {
                Button {
                    showLicense = true
                } label: {
                    Label("开源声明", systemImage: "doc.text")
                }
                LabeledContent("版本", value: appVersion)
                LabeledContent("协议", value: "GPL-2.0")
            }

            Section {
                Text("本应用为非官方第三方客户端，所有内容均来自轻小说文库网站，仅供学习交流使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("设置")
        .sheet(isPresented: $showWeb) {
            WebSheet(url: URL(string: "https://www.wenku8.net/wap/"))
        }
        .sheet(isPresented: $showLicense) {
            LicenseSheet()
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
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

    private func applyRelaySettings() {
        relayStore.setEnabled(relayEnabled)
        RelayClient.shared.configure(
            RelayConfiguration(isEnabled: relayEnabled),
            provider: relayEnabled ? BuiltinAppVerProvider() : nil
        )
        if relayEnabled {
            Task { await RelayClient.shared.setMinimumInterval(relayStore.minimumInterval) }
            accountMessage = "中转服务已启用"
        } else {
            accountMessage = "已关闭中转服务，将使用网页版数据"
        }
    }

    @ViewBuilder
    private var relaySection: some View {
        Section {
            Toggle(isOn: $relayEnabled) {
                Label("启用中转服务", systemImage: "antenna.radiowaves.left.and.right")
            }
            .onChange(of: relayEnabled) { _, _ in
                applyRelaySettings()
            }

        } header: {
            Text("中转服务")
        } footer: {
            Text("""
            中转服务提供网页版匿名访问不到的排行榜、文库分类，\
            以及部分因站点限制无法在网页版阅读的正文。\
            它是第三方公益服务，有独立配额，因此本应用强制对请求限速。\
            关闭后将改用网页版数据，排行榜会回退为年度榜单。
            """)
            .font(.footnote)
        }
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
