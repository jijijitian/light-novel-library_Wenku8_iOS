import SwiftUI
import Wenku8Core

/// Reading preferences: typography, layout and the reader's chrome.
struct ReaderSettingsView: View {
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.lineSpacingKey) private var lineSpacing = ReaderPreferences.defaultLineSpacing
    @AppStorage(ReaderPreferences.paragraphSpacingKey) private var paragraphSpacing = ReaderPreferences.defaultParagraphSpacing
    @AppStorage(ReaderPreferences.layoutKey) private var layoutRaw = ReaderLayout.vertical.rawValue
    @AppStorage(ReaderPreferences.indentKey) private var indentFirstLine = false
    @AppStorage(ReaderPreferences.collapsedInfoKey) private var collapsedInfo = true
    @AppStorage(ReaderMetrics.topInsetKey) private var topInset = ReaderMetrics.defaultTopInset
    @AppStorage(ReaderMetrics.bottomInsetKey) private var bottomInset = ReaderMetrics.defaultBottomInset

    private var isDefaultTypography: Bool {
        fontSize == ReaderPreferences.defaultFontSize
            && lineSpacing == ReaderPreferences.defaultLineSpacing
            && paragraphSpacing == ReaderPreferences.defaultParagraphSpacing
    }

    var body: some View {
        Form {
            Section {
                slider(
                    title: "字号",
                    symbol: "textformat.size",
                    value: $fontSize,
                    range: ReaderPreferences.fontSizeRange,
                    step: 1,
                    suffix: "pt"
                )
                slider(
                    title: "行距",
                    symbol: "text.alignleft",
                    value: $lineSpacing,
                    range: ReaderPreferences.lineSpacingRange,
                    step: 1
                )
                slider(
                    title: "段间距",
                    symbol: "text.justify.leading",
                    value: $paragraphSpacing,
                    range: ReaderPreferences.paragraphSpacingRange,
                    step: 1
                )

                Button {
                    fontSize = ReaderPreferences.defaultFontSize
                    lineSpacing = ReaderPreferences.defaultLineSpacing
                    paragraphSpacing = ReaderPreferences.defaultParagraphSpacing
                } label: {
                    Label("恢复默认字号与间距", systemImage: "arrow.counterclockwise")
                }
                .disabled(isDefaultTypography)
            } header: {
                Text("排版")
            }

            Section {
                // A segmented Picker bound to @AppStorage does not reliably re-read
                // the stored value inside a Form, so the selection goes through an
                // explicit Binding.
                Picker("翻页方式", selection: Binding(
                    get: { ReaderLayout(rawValue: layoutRaw) ?? .vertical },
                    set: { layoutRaw = $0.rawValue }
                )) {
                    ForEach(ReaderLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImage)
                            .tag(layout)
                    }
                }

                Toggle(isOn: $indentFirstLine) {
                    describe("首行缩进", detail: "每段首行缩进两个字符")
                }
            } header: {
                Text("布局")
            }

            Section {
                Toggle(isOn: $collapsedInfo) {
                    describe("沉浸式标题", detail: "隐藏菜单时在顶部显示浅色章节标题")
                }
                slider(
                    title: "顶部留白",
                    symbol: "arrow.up.to.line",
                    value: $topInset,
                    range: ReaderMetrics.insetRange,
                    step: 2,
                    suffix: "pt"
                )
                slider(
                    title: "底部留白",
                    symbol: "arrow.down.to.line",
                    value: $bottomInset,
                    range: ReaderMetrics.insetRange,
                    step: 2,
                    suffix: "pt"
                )
            } header: {
                Text("沉浸式")
            } footer: {
                Text("留白决定正文与屏幕上下边缘的距离。")
                    .font(.footnote)
            }
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Pieces

    /// A labelled slider with its current value trailing the title.
    private func slider(
        title: String,
        symbol: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(suffix.map { "\(Int(value.wrappedValue)) \($0)" } ?? "\(Int(value.wrappedValue))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    /// Title plus a caption, used by the toggles.
    private func describe(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "text.append")
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
