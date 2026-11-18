import SwiftUI
import Wenku8Core

/// Mirror choice and the optional relay service.
struct DataSourceSettingsView: View {
    @EnvironmentObject private var account: AccountStore
    @AppStorage("site.domain") private var domainRaw = SiteDomain.net.rawValue
    @State private var relayEnabled = RelayCredentialStore.shared.isEnabled
    @State private var relayMessage: String?
    /// Outcome of the login check that follows a data source change.
    @State private var sessionMessage: String?

    private let relayStore = RelayCredentialStore.shared

    var body: some View {
        Form {
            Section {
                Picker("站点域名", selection: Binding(
                    get: { domainRaw },
                    set: { newValue in
                        domainRaw = newValue
                        Wenku8Client.shared.use(domain: SiteDomain(rawValue: newValue) ?? .net)
                        // The session lives in domain-scoped cookies, so the new domain
                        // starts out signed out. Check once and repair if possible.
                        verifySession()
                    }
                )) {
                    ForEach(SiteDomain.allCases) { domain in
                        Text(domain.title).tag(domain.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("站点域名")
            } footer: {
                Text("两个域名内容一致；某个域名访问不通时可以切换到另一个。网页版数据走这个域名。")
                    .font(.footnote)
            }

            Section {
                Toggle(isOn: $relayEnabled) {
                    Label("启用中转服务", systemImage: "antenna.radiowaves.left.and.right")
                }
                .onChange(of: relayEnabled) { _, _ in applyRelaySettings() }

                if let relayMessage {
                    Text(relayMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("中转服务")
            } footer: {
                Text("""
                开启后首页、排行、文库、搜索、书籍信息与正文全部改由中转服务提供，\
                不再混用网页版数据；中转失败会直接提示，不会换成网页版结果。\
                账号密码与网页版相同，登录时一并登录。\
                它是第三方公益服务，有独立配额，因此本应用强制对请求限速。\
                关闭后改用网页版；但排行榜网页版未登录时无法访问，\
                届时会回退为年度榜单（应用内「年度排行」也可直接查看）。
                """)
                .font(.footnote)
            }
            if let sessionMessage {
                Section {
                    Label(sessionMessage, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.footnote)
                } header: {
                    Text("登录状态")
                } footer: {
                    Text("切换域名或开关中转服务后，应用会检查一次登录是否仍然有效；失效时会用本次运行中登录过的账号密码自动重登。密码只在内存中保留，退出应用即清除。")
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("数据来源")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func applyRelaySettings() {
        relayStore.setEnabled(relayEnabled)
        RelayClient.shared.configure(
            RelayConfiguration(isEnabled: relayEnabled),
            provider: relayEnabled ? BuiltinAppVerProvider() : nil
        )
        if relayEnabled {
            Task { await RelayClient.shared.setMinimumInterval(relayStore.minimumInterval) }
            relayMessage = "中转服务已启用"
        } else {
            relayMessage = "已关闭中转服务，将使用网页版数据"
        }
        // The relay authenticates separately from the website, so turning it on has to
        // sign in there too, and turning it off can leave a relay-only session behind.
        verifySession()
    }

    /// Re-checks the login after the data source changed and reports what happened.
    private func verifySession() {
        Task {
            sessionMessage = await account.verifySessionAfterSourceChange()
        }
    }
}
