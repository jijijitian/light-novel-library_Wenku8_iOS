import SwiftUI
import Wenku8Core

/// Mirror choice and the optional relay service.
struct DataSourceSettingsView: View {
    @AppStorage("site.domain") private var domainRaw = SiteDomain.net.rawValue
    @State private var relayEnabled = RelayCredentialStore.shared.isEnabled
    @State private var message: String?

    private let relayStore = RelayCredentialStore.shared

    var body: some View {
        Form {
            Section {
                Picker("站点域名", selection: Binding(
                    get: { domainRaw },
                    set: { newValue in
                        domainRaw = newValue
                        Wenku8Client.shared.use(domain: SiteDomain(rawValue: newValue) ?? .net)
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

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("中转服务")
            } footer: {
                Text("""
                开启后首页、排行、文库、搜索、书籍信息与正文全部改由中转服务提供，\
                不再混用网页版数据；中转失败会直接提示，而不会偷偷换成网页版结果。\
                账号密码与网页版相同，登录时一并登录。\
                它是第三方公益服务，有独立配额，因此本应用强制对请求限速。\
                关闭后全部改由网页版提供，排行榜会回退为年度榜单。
                """)
                .font(.footnote)
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
            message = "中转服务已启用"
        } else {
            message = "已关闭中转服务，将使用网页版数据"
        }
    }
}
