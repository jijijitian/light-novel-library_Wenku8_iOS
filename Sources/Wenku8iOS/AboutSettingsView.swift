import SwiftUI

/// Version, licence and the project link.
struct AboutSettingsView: View {
    var onShowLicense: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("版本", value: Self.appVersion)
                LabeledContent("协议", value: "GPL-2.0")
                Button {
                    onShowLicense()
                } label: {
                    Label("开源声明", systemImage: "doc.text")
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/jijijitian/light-novel-library_Wenku8_iOS")!) {
                    Label("项目主页", systemImage: "globe")
                }
                Link(destination: URL(string: "https://github.com/MewX/light-novel-library_Wenku8_Android")!) {
                    Label("原始 Android 版", systemImage: "link")
                }
            } header: {
                Text("相关链接")
            }

            Section {
                Text("本应用为非官方第三方客户端，所有内容均来自轻小说文库网站，仅供学习交流使用。版权归原作者与出版机构所有。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
