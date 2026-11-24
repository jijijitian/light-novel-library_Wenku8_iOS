import SwiftUI

/// Version, licence and the project link.
struct AboutSettingsView: View {
    var onShowLicense: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Panel {
                    PanelRow {
                        Text("版本")
                        Spacer(minLength: 0)
                        Text(Self.appVersion).foregroundStyle(.secondary)
                    }
                    Divider()
                    PanelRow {
                        Text("协议")
                        Spacer(minLength: 0)
                        Text("GPL-2.0").foregroundStyle(.secondary)
                    }
                    Divider()
                    Button {
                        onShowLicense()
                    } label: {
                        PanelRow {
                            Label("开源声明", systemImage: "doc.text")
                            Spacer(minLength: 0)
                            Chevron()
                        }
                    }
                    .buttonStyle(.plain)
                }

                Panel(title: "相关链接") {
                    Link(destination: URL(string: "https://github.com/jijijitian/light-novel-library_Wenku8_iOS")!) {
                        PanelRow {
                            Label("项目主页", systemImage: "globe")
                            Spacer(minLength: 0)
                        }
                    }
                    Divider()
                    Link(destination: URL(string: "https://github.com/MewX/light-novel-library_Wenku8_Android")!) {
                        PanelRow {
                            Label("原始 Android 版", systemImage: "link")
                            Spacer(minLength: 0)
                        }
                    }
                }

                Text("本应用为非官方第三方客户端，所有内容均来自轻小说文库网站，仅供学习交流使用。版权归原作者与出版机构所有。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
