import SwiftUI
import Wenku8Core

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var rows: [HomeRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published private(set) var lastUpdated: Date?

    private let service: NovelService
    private var hasLoaded = false

    init(service: NovelService = NovelService()) {
        self.service = service
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.homeRows()
            rows = result
            lastUpdated = Date()
            error = nil
            hasLoaded = true
        } catch {
            self.error = error
        }
    }

    func loadFallback(_ board: RankBoard) async throws -> [NovelSummary] {
        try await service.rank(board, page: 1)
    }
}

struct HomeView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var model = HomeViewModel()
    @State private var heroIndex = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let error = model.error, model.rows.isEmpty {
                    ErrorStateView(error: error) {
                        Task { await model.reload() }
                    }
                } else if model.rows.isEmpty && model.isLoading {
                    LoadingRow(text: "正在载入文库首页…")
                } else {
                    if let hero = heroNovels.first {
                        HeroBanner(novels: heroNovels, selection: $heroIndex) { novel in
                            router.open(.novel(novel.id))
                        }
                        .onTapGesture {
                            router.open(.novel(hero.id))
                        }
                    }

                    continueReading

                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                SectionHeader(
                                    title: row.section.title,
                                    subtitle: row.section.subtitle,
                                    symbol: row.section.symbol
                                )
                                Button {
                                    router.open(.rankList(row.section.board))
                                } label: {
                                    Text("更多")
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                            }
                            NovelGrid(novels: Array(row.items.prefix(6))) { novel in
                                router.open(.novel(novel.id))
                            }
                        }
                    }

                    if model.rows.isEmpty {
                        EmptyStateView(
                            symbol: "books.vertical",
                            title: "暂时没有内容",
                            message: "文库首页可能需要登录才能显示榜单，试试下拉刷新。",
                            actionTitle: "重新加载"
                        ) {
                            Task { await model.reload() }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background { AppBackground() }
        .navigationTitle("轻小说文库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.reload() }
                } label: {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoading)
            }
        }
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
    }

    private var heroNovels: [NovelSummary] {
        let items = model.rows.first(where: { $0.section == .hot })?.items ?? []
        return Array(items.prefix(3))
    }

    @ViewBuilder
    private var continueReading: some View {
        if let entry = store.progress.values.sorted(by: { $0.updated > $1.updated }).first,
           let novel = store.saved.first(where: { $0.id == entry.novelID }) {
            Button {
                router.open(.novel(novel.id))
            } label: {
                HStack(spacing: 12) {
                    CoverCard(url: novel.coverURL, title: novel.title, width: 52, height: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("继续阅读").font(.caption).foregroundStyle(.secondary)
                        Text(novel.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(entry.chapterTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                .padding(12)
                .glassCard(cornerRadius: 20)
            }
            .buttonStyle(.plain)
        }
    }
}

struct HeroBanner: View {
    var novels: [NovelSummary]
    @Binding var selection: Int
    var onSelect: (NovelSummary) -> Void

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(novels.enumerated()), id: \.element.id) { index, novel in
                ZStack(alignment: .bottomLeading) {
                    AppTheme.gradient(for: novel.id)
                    CoverCard(url: novel.coverURL, title: novel.title, width: 108, height: 154)
                        .rotation3DEffect(.degrees(-8), axis: (x: 0, y: 1, z: 0))
                        .padding(20)
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer(minLength: 0)
                        Text("编辑推荐")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassCapsule()
                        Text(novel.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .shadow(radius: 4, y: 1)
                    }
                    .padding(16)
                    .frame(maxWidth: 260, alignment: .leading)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .tag(index)
                .onTapGesture { onSelect(novel) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .systemBackground).opacity(0.92),
                    Color(uiColor: .secondarySystemBackground).opacity(0.55),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(AppTheme.accent.opacity(0.22))
                .frame(width: 260, height: 260)
                .blur(radius: 80)
                .offset(x: -120, y: -260)
            Circle()
                .fill(Color.orange.opacity(0.16))
                .frame(width: 240, height: 240)
                .blur(radius: 90)
                .offset(x: 140, y: 300)
        }
        .ignoresSafeArea()
    }
}
