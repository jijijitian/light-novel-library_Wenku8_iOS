import SwiftUI
import Wenku8Core

/// Where the app reads from: which of the site's mirrors.
///
/// The mirror is the only choice the app makes about where content comes from.
struct DataSourceSettingsView: View {
    @AppStorage("site.domain") private var domainRaw = SiteDomain.net.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "镜像", subtitle: "选择访问的站点域名", symbol: "globe.asia.australia")
                    Picker("镜像", selection: Binding(
                        get: { domainRaw },
                        set: { newValue in
                            domainRaw = newValue
                            Wenku8Client.shared.use(domain: SiteDomain(rawValue: newValue) ?? .net)
                        }
                    )) {
                        ForEach(SiteDomain.allCases) { domain in
                            Text(domain.shortTitle).tag(domain.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 22)

                Text("三个域名指向同一个站点。某个域名无法访问时，换一个即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("数据来源")
        .navigationBarTitleDisplayMode(.inline)
    }
}
