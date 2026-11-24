import SwiftUI

/// App-level appearance: light / dark / follow the system.
struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(CoverPalette.storageKey) private var coverTint = false

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Panel(title: "外观模式") {
                    // One row per mode rather than a picker: the inline picker drew its options
                    // as a list inside the panel and took the panel over, and these rows read as
                    // the same kind of thing as the rest of the screen.
                    ForEach(Array(AppAppearance.allCases.enumerated()), id: \.element) { index, mode in
                        if index > 0 {
                            Divider().opacity(0.4)
                        }
                        Button {
                            appearanceRaw = mode.rawValue
                        } label: {
                            PanelRow {
                                Label(mode.title, systemImage: mode.systemImage)
                                Spacer(minLength: 0)
                                if appearance == mode {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Panel {
                    Toggle(isOn: $coverTint) {
                        Label("封面取色", systemImage: "paintpalette")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                Text("外观模式影响书架、设置等界面，阅读器有自己的纸张配色，不受此处影响。开启封面取色后，书籍详情页的背景会取自该书封面的主色调。")
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
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}
