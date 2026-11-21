import SwiftUI
import Wenku8Core

/// Mirror choice and the optional relay service.
struct DataSourceSettingsView: View {
    @EnvironmentObject private var account: AccountStore
    @AppStorage("site.domain") private var domainRaw = SiteDomain.net.rawValue
    @State private var relayEnabled = RelayCredentialStore.shared.isEnabled
    /// Both sources at once. Only offered while the relay is on — there is nothing to mix
    /// with otherwise.
    @State private var hybridEnabled = RelayCredentialStore.shared.isHybridEnabled
    /// Outcome of the login check that follows a data source change.
    @State private var sessionMessage: String?
    /// Set when the switch left the app signed out, so the section offers a way back in.
    @State private var needsLogin = false
    @State private var showLogin = false
    /// Results of the last connectivity run, one row per source that was asked.
    @State private var checks: [NovelService.Connectivity] = []
    @State private var isChecking = false

    private let relayStore = RelayCredentialStore.shared

    var body: some View {
        Form {
            Section {
                Picker("站点域名", selection: Binding(
                    get: { domainRaw },
                    set: { newValue in
                        domainRaw = newValue
                        Wenku8Client.shared.use(domain: SiteDomain(rawValue: newValue) ?? .net)
                        // The session survives the switch: cc and com both redirect to net,
                        // so the cookie the site sets belongs to net whichever name was
                        // used. The check is still run, because that is a property of the
                        // site rather than a promise, and it also re-points the login state
                        // at the new source.
                        verifySession()
                    }
                )) {
                    ForEach(SiteDomain.allCases) { domain in
                        Text(domain.shortTitle).tag(domain.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("站点域名")
            } footer: {
                Text("当前数据源不可用时，可切换数据源以重试。")
                    .font(.footnote)
            }

            Section {
                Toggle(isOn: $relayEnabled) {
                    Label("启用中转服务", systemImage: "antenna.radiowaves.left.and.right")
                }
                .onChange(of: relayEnabled) { _, _ in
                    applyRelaySettings()
                    // Re-read rather than keep the stale state: the switch was hidden while
                    // the relay was off, and the stored preference outlives that.
                    if relayEnabled { hybridEnabled = relayStore.isHybridEnabled }
                }

                if relayEnabled {
                    Toggle(isOn: $hybridEnabled) {
                        Label("混合模式", systemImage: "arrow.triangle.branch")
                    }
                    .onChange(of: hybridEnabled) { _, _ in applyRelaySettings() }
                }

            } header: {
                Text("中转服务")
            } footer: {
                Text("""
                中转模式：使用中转api获取数据，中转有配额限制，请求自动限速。
                混合模式：同时使用网页数据源与中转数据源，双方数据互补。
                """)
                .font(.footnote)
            }
            Section {
                Button {
                    Task { await runConnectivityChecks() }
                } label: {
                    HStack(spacing: 8) {
                        if isChecking {
                            ProgressView().controlSize(.small)
                            Text("正在检测…")
                        } else {
                            Label("检测连接", systemImage: "waveform.path.ecg")
                        }
                    }
                }
                .disabled(isChecking)

                ForEach(checks, id: \.target) { check in
                    connectivityRow(check)
                }
            } header: {
                Text("连接检测")
            } footer: {
                Text("检测本机能否连上所选站点与中转服务。中转服务两次请求之间至少间隔 1.2 秒，连续检测时它的响应时间里会包含这段等待。")
                    .font(.footnote)
            }

            if let sessionMessage {
                Section {
                    Label(
                        sessionMessage,
                        systemImage: needsLogin
                            ? "person.crop.circle.badge.exclamationmark"
                            : "person.crop.circle.badge.checkmark"
                    )
                    .font(.footnote)
                    if needsLogin {
                        Button {
                            showLogin = true
                        } label: {
                            Label("登录", systemImage: "person.crop.circle")
                        }
                    }
                } header: {
                    Text("登录状态")
                } footer: {
                    Text("切换域名或开关中转服务后，应用会检查一次登录是否仍然有效。应用不保存账号密码，失效时需要重新登录。")
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("数据来源")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            // Signing in from here settles the check the switch raised.
            if signedIn {
                needsLogin = false
                sessionMessage = "已登录"
            }
        }
    }

    private func applyRelaySettings() {
        relayStore.setEnabled(relayEnabled)
        // Hybrid is a property of the relay: with it off there is nothing to mix with, so
        // the preference is left untouched rather than cleared.
        if relayEnabled { relayStore.setHybridEnabled(hybridEnabled) }
        RelayClient.shared.configure(
            RelayConfiguration(
                isEnabled: relayEnabled,
                isHybrid: relayEnabled && hybridEnabled
            ),
            provider: relayEnabled ? BuiltinAppVerProvider() : nil
        )
        if relayEnabled {
            Task { await RelayClient.shared.setMinimumInterval(relayStore.minimumInterval) }
        }
        // The relay authenticates separately from the website, so turning it on has to
        // sign in there too, and turning it off can leave a relay-only session behind.
        verifySession()
    }

    /// Re-checks the login after the data source changed and reports what happened.
    /// Asks each source in use whether it answers, and how quickly.
    private func runConnectivityChecks() async {
        isChecking = true
        defer { isChecking = false }

        let service = NovelService()
        var results: [NovelService.Connectivity] = []
        // Sequential on purpose: the relay paces requests, so running both at once would
        // charge the site's timing to the relay's queue.
        results.append(await service.checkSiteConnectivity())
        if relayEnabled {
            results.append(await service.checkRelayConnectivity())
        }
        checks = results
    }

    private func connectivityRow(_ check: NovelService.Connectivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(check.isReachable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(check.target == .site ? "站点" : "中转服务")
                Spacer(minLength: 0)
                if let latency = check.latency {
                    Text(String(format: "%.2f 秒", latency))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(check.isReachable ? "可达" : "不可达")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(check.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func verifySession() {
        Task {
            switch await account.verifySessionAfterSourceChange() {
            case .notSignedIn:
                sessionMessage = nil
                needsLogin = false
            case .valid(let name):
                sessionMessage = "登录状态正常（\(name)）"
                needsLogin = false
            case .expired:
                sessionMessage = "切换数据源后登录已失效"
                needsLogin = true
            }
        }
    }
}
