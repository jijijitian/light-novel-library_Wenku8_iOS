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
                Text("两个域名内容一致；某个域名访问不通时可以切换到另一个。首页抓取仍会自动回退。")
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
                中转服务提供网页版匿名访问不到的排行榜、文库分类，\
                以及部分因站点限制无法在网页版阅读的正文。\
                它是第三方公益服务，有独立配额，因此本应用强制对请求限速。\
                关闭后将改用网页版数据，排行榜会回退为年度榜单。
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
