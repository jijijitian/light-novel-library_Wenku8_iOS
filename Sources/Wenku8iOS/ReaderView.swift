import SwiftUI
import Wenku8Core

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var chapters: [ChapterLink]
    @Published var index: Int
    @Published private(set) var content: ChapterContent?
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    let novelID: Int
    private let service: NovelService
    private var cache: [Int: ChapterContent] = [:]
    private var loadToken = UUID()

    init(novelID: Int, chapters: [ChapterLink], startIndex: Int, service: NovelService = NovelService()) {
        self.novelID = novelID
        self.chapters = chapters
        self.index = min(max(0, startIndex), max(0, chapters.count - 1))
        self.service = service
    }

    var current: ChapterLink? {
        guard chapters.indices.contains(index) else { return nil }
        return chapters[index]
    }

    var canGoPrevious: Bool { index > 0 }
    var canGoNext: Bool { index + 1 < chapters.count }

    func load() async {
        guard let chapter = current else { return }
        if let cached = cache[chapter.id] {
            content = cached
            error = nil
            return
        }
        let token = UUID()
        loadToken = token
        isLoading = true
        error = nil
        defer { if loadToken == token { isLoading = false } }
        do {
            let result = try await service.chapter(aid: novelID, cid: chapter.id)
            cache[chapter.id] = result
            guard loadToken == token else { return }
            content = result
        } catch {
            guard loadToken == token else { return }
            self.error = error
        }
    }

    func goPrevious() async {
        guard canGoPrevious else { return }
        index -= 1
        await load()
    }

    func goNext() async {
        guard canGoNext else { return }
        index += 1
        await load()
    }

    func jump(to newIndex: Int) async {
        guard chapters.indices.contains(newIndex) else { return }
        index = newIndex
        await load()
    }
}

struct ReaderTheme: Equatable {
    var background: Color
    var text: Color

    static let paper = ReaderTheme(
        background: Color(red: 0.98, green: 0.96, blue: 0.91),
        text: Color(red: 0.16, green: 0.14, blue: 0.12)
    )
    static let sepia = ReaderTheme(
        background: Color(red: 0.93, green: 0.88, blue: 0.78),
        text: Color(red: 0.22, green: 0.18, blue: 0.12)
    )
    static let night = ReaderTheme(
        background: Color(red: 0.07, green: 0.07, blue: 0.09),
        text: Color(red: 0.82, green: 0.82, blue: 0.85)
    )
    static let system = ReaderTheme(
        background: Color(uiColor: .systemBackground),
        text: Color(uiColor: .label)
    )

    static let all: [(name: String, theme: ReaderTheme)] = [
        ("纸白", .paper),
        ("护眼", .sepia),
        ("夜间", .night),
        ("跟随系统", .system),
    ]
}

struct ReaderView: View {
    var novelID: Int
    var chapters: [ChapterLink]
    var startIndex: Int

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ReaderViewModel
    @State private var showChrome = true
    @State private var showCatalog = false
    @AppStorage("reader.theme") private var themeName = "纸白"
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.vertical") private var isVertical = false

    init(novelID: Int, chapters: [ChapterLink], startIndex: Int) {
        self.novelID = novelID
        self.chapters = chapters
        self.startIndex = startIndex
        _model = StateObject(
            wrappedValue: ReaderViewModel(novelID: novelID, chapters: chapters, startIndex: startIndex)
        )
    }

    private var theme: ReaderTheme {
        ReaderTheme.all.first { $0.name == themeName }?.theme ?? .paper
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            content

            if showChrome {
                chrome
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(showChrome ? .visible : .hidden, for: .navigationBar)
        // Reading is a full-screen mode: the app's dock must not sit under the
        // text, otherwise it both steals vertical space and clashes with the
        // reader's own glass control bar. The dock is hand-drawn in `RootView`,
        // which hides it whenever the current stack has a `.reader` route on top.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    saveProgress()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .principal) {
                Text(model.current?.title ?? "")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCatalog = true
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
        }
        .task {
            await model.load()
            recordProgress()
        }
        .onChange(of: model.index) { _, _ in
            recordProgress()
        }
        .onDisappear { saveProgress() }
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(model: model)
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.current?.title ?? "")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isLoading && model.content == nil {
                    ProgressView()
                        .tint(theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let error = model.error {
                    VStack(spacing: 12) {
                        Text(errorMessage(error))
                            .font(.subheadline)
                            .foregroundStyle(theme.text.opacity(0.7))
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await model.load() }
                        }
                        .prominentGlassButtonShape()
                        .tint(AppTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else if let content = model.content {
                    ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let text):
                            Text(text)
                                .font(.system(size: fontSize))
                                .lineSpacing(lineSpacing)
                                .foregroundStyle(theme.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        case .image(let url):
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFit()
                                } else {
                                    ProgressView().tint(theme.text)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    navigationButtons
                }
            }
            .frame(maxWidth: isVertical ? .infinity : 680, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, showChrome ? 190 : 46)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) { showChrome.toggle() }
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await model.goPrevious()
                    recordProgress()
                }
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .secondaryGlassButtonShape(capsule: false)
            .disabled(!model.canGoPrevious)

            Button {
                Task {
                    await model.goNext()
                    recordProgress()
                }
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .prominentGlassButtonShape()
            .tint(AppTheme.accent)
            .disabled(!model.canGoNext)
        }
        .padding(.top, 26)
    }

    private var chrome: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Button {
                        Task { await model.goPrevious() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 40, height: 40)
                    }
                    .secondaryGlassButtonShape(capsule: false)
                    .disabled(!model.canGoPrevious)

                    Button {
                        showCatalog = true
                    } label: {
                        VStack(spacing: 1) {
                            Text("目录")
                                .font(.caption.weight(.semibold))
                            Text("\(model.index + 1)/\(model.chapters.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .secondaryGlassButtonShape(capsule: false)

                    Button {
                        Task { await model.goNext() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 40, height: 40)
                    }
                    .prominentGlassButtonShape()
                    .tint(AppTheme.accent)
                    .disabled(!model.canGoNext)
                }

                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size")
                            .font(.caption)
                        Slider(value: $fontSize, in: 14...28, step: 1)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "text.alignleft")
                            .font(.caption)
                        Slider(value: $lineSpacing, in: 2...16, step: 1)
                    }
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(ReaderTheme.all, id: \.name) { item in
                        Button {
                            themeName = item.name
                        } label: {
                            Circle()
                                .fill(item.theme.background)
                                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            themeName == item.name ? AppTheme.accent : .clear,
                                            lineWidth: 2
                                        )
                                )
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text(themeName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .glassCard(cornerRadius: 26)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func recordProgress() {
        guard let chapter = model.current else { return }
        store.record(novelID: novelID, chapterID: chapter.id, chapterTitle: chapter.title)
    }

    private func saveProgress() {
        recordProgress()
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct CatalogSheet: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        Task {
                            await model.jump(to: index)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if index == model.index {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("章节目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
