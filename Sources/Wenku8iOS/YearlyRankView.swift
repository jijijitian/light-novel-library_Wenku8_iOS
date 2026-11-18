import SwiftUI
import Wenku8Core

/// The yearly boards (年度排行), by year.
///
/// These were previously reachable only by tapping a year chip that sat above a normal
/// ranking, which replaced that ranking rather than opening a destination. They have
/// their own screen now, so the year selector has a home and a normal board is never
/// switched out from under the reader.
struct YearlyRankView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = YearlyRankViewModel()
    @State private var year = SugoiParser.availableYears.first ?? 2026
    @State private var showWeb = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                yearPicker

                if model.isLoading && model.sections.isEmpty {
                    LoadingRow()
                } else if let error = model.error, model.sections.isEmpty {
                    VStack(spacing: 12) {
                        ErrorStateView(error: error) {
                            Task { await model.load(year: year, force: true) }
                        }
                        Button("在网页版查看") { showWeb = true }
                            .secondaryGlassButtonShape()
                    }
                } else {
                    ForEach(model.sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: section.caption, symbol: "trophy.fill")
                            NovelGrid(novels: section.novels) { novel in
                                // An entry the library does not stock has no page to open;
                                // it is shown so the ranking is complete, not so it can be
                                // navigated.
                                guard novel.id > 0 else { return }
                                router.open(.novel(novel.id))
                            }
                        }
                        .padding(14)
                        .glassCard(cornerRadius: 22)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background { AppBackground() }
        .navigationTitle("年度排行")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(year: year, force: true) }
        .task { await model.load(year: year) }
        .onChange(of: year) { _, newValue in
            Task { await model.load(year: newValue, force: true) }
        }
        .sheet(isPresented: $showWeb) {
            WebSheet(url: URL(string: "https://wenku8.mewx.org/"))
        }
    }

    private var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(SugoiParser.availableYears, id: \.self) { value in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { year = value }
                        } label: {
                            Text("\(String(value))年度")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .glassCapsule(
                            tint: year == value ? AppTheme.accent.opacity(0.55) : nil,
                            interactive: true
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

@MainActor
final class YearlyRankViewModel: ObservableObject {
    @Published private(set) var sections: [SugoiParser.Section] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private let service: NovelService
    private var loadedYear: Int?
    /// Identifies the current load, so a superseded one cannot write over its result.
    private var generation = 0

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func load(year: Int, force: Bool = false) async {
        guard force || loadedYear != year else { return }
        // A pull used to be dropped while a load was in flight.
        if isLoading && !force { return }
        let isNewYear = loadedYear != year
        generation &+= 1
        let mine = generation
        isLoading = true
        defer { if generation == mine { isLoading = false } }
        do {
            let parsed = try await service.sugoi(year: year)
            guard generation == mine else { return }
            sections = parsed.sections
            error = sections.isEmpty ? Wenku8Error.unavailable("\(year) 年度榜单没有数据") : nil
            loadedYear = year
        } catch {
            guard generation == mine else { return }
            if isNewYear {
                // A different year has nothing in common with what is on screen.
                sections = []
                self.error = error
            } else {
                // Refreshing the same year keeps its list rather than blanking the page.
                self.error = sections.isEmpty ? error : nil
            }
        }
    }
}
