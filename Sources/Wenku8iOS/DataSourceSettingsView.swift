import SwiftUI
import Wenku8Core

/// Where the app reads from: which of the site's mirrors.
///
/// The mirror is the only choice the app makes about where content comes from, so the
/// screen is a list of the three hosts rather than a form. Each row says what it is and
/// whether it is the one in use; tapping switches immediately and confirms.
struct DataSourceSettingsView: View {
    @AppStorage("site.domain") private var domainRaw = SiteDomain.net.rawValue
    @State private var checks: [NovelService.Connectivity] = []
    @State private var isChecking = false

    private var current: SiteDomain {
        SiteDomain(rawValue: domainRaw) ?? .net
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(
                        title: "镜像",
                        subtitle: "三处指向同一个站点",
                        symbol: "globe.asia.australia"
                    )
                    .padding(.bottom, 12)

                    ForEach(SiteDomain.allCases) { domain in
                        Button {
                            select(domain)
                        } label: {
                            row(domain)
                        }
                        .buttonStyle(.plain)
                        if domain != SiteDomain.allCases.last {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 22)

                // Asks the selected mirror whether it answers at all, and how quickly.
                // This is the question a reader has when a page stays empty and they do
                // not know whether to change mirror or wait.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionHeader(title: "连接检测", subtitle: "确认选中的镜像能否访问", symbol: "antenna.radiowaves.left.and.right")
                        Button {
                            Task { await runCheck() }
                        } label: {
                            if isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isChecking)
                    }

                    if checks.isEmpty {
                        Text("尚未检测")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                            connectivityRow(check)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 22)

                Label(
                    "某个域名打不开时换一个即可，账号与书架不会受影响。",
                    systemImage: "info.circle"
                )
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

    private func connectivityRow(_ check: NovelService.Connectivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(check.isReachable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("站点")
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

    private func runCheck() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        checks = [await NovelService().checkSiteConnectivity()]
    }

    private func row(_ domain: SiteDomain) -> some View {
        HStack(spacing: 12) {
            Text(domain.title)
                .font(.subheadline.weight(.medium))

            Spacer(minLength: 0)

            if domain == current {
                Text("使用中")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func select(_ domain: SiteDomain) {
        guard domain.rawValue != domainRaw else { return }
        domainRaw = domain.rawValue
        Wenku8Client.shared.use(domain: domain)
    }
}
