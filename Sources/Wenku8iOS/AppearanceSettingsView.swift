import SwiftUI

/// App-level appearance: light / dark / follow the system.
struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Form {
            Section {
                Picker("外观模式", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("外观模式")
            } footer: {
                Text("影响书架、设置等界面。阅读器有自己的纸张配色，不受此处影响。")
                    .font(.footnote)
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}
