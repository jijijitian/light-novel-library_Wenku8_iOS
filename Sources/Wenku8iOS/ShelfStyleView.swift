import SwiftUI

/// Which layout the shelf uses: a list of rows, or a grid of covers.
struct ShelfStyleView: View {
    @AppStorage(ShelfStyle.storageKey) private var styleRaw = ShelfStyle.list.rawValue

    private var style: ShelfStyle {
        ShelfStyle(rawValue: styleRaw) ?? .list
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Panel(title: "书架样式") {
                    ForEach(Array(ShelfStyle.allCases.enumerated()), id: \.element) { index, option in
                        if index > 0 {
                            Divider().opacity(0.4)
                        }
                        Button {
                            styleRaw = option.rawValue
                        } label: {
                            PanelRow {
                                Label(option.title, systemImage: option.systemImage)
                                Spacer(minLength: 0)
                                if style == option {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background { AppBackground() }
        .navigationTitle("书架样式")
        .navigationBarTitleDisplayMode(.inline)
    }
}
