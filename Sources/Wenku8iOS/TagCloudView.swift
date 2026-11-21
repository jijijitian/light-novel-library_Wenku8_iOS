import SwiftUI
import Wenku8Core

/// The site's tag cloud, under its own name: Tags云集.
///
/// Grouped the way the site groups it — 日常系属性, 幻想系属性 and so on — because a hundred
/// tags in one flat list are not browsable. Tags are website content; with the relay alone
/// there is nothing to list, which the screen says rather than appearing empty.
struct TagCloudView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var groups: [DesktopParser.TagGroup] = []
    @State private var isLoading = false
    @State private var error: Error?
    @State private var savedAt: Date?

    var body: some View {
        ScrollView {
            if isLoading && groups.isEmpty {
                LoadingRow(text: "正在载入 Tags 云集…")
            } else if let error, groups.isEmpty {
                ErrorStateView(error: error) {
                    Task { await load(force: true) }
                }
            } else if groups.isEmpty {
                EmptyStateView(
                    symbol: "number",
                    title: "暂时没有标签",
                    message: "站点没有返回标签列表。"
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: group.title, symbol: "number")
                            FlowLayout(spacing: 8) {
                                ForEach(group.tags, id: \.self) { tag in
                                    Button {
                                        router.open(.tag(tag))
                                    } label: {
                                        TagChip(text: tag)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 22)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .background { AppBackground() }
        .navigationTitle("Tags云集")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await Task { await load(force: true) }.value }
        .task {
            if groups.isEmpty { restore() }
            await load()
        }
    }

    // MARK: - Stored groups

    /// The cloud changes a few times a year, so it is kept between launches like the home
    /// screen's rows: paint what was stored, then refresh over it.
    private struct CloudSnapshot: Codable {
        var savedAt: Date
        var groups: [DesktopParser.TagGroup]
    }

    private static var snapshotURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TagCloudSnapshot.json")
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(CloudSnapshot.self, from: data) else {
            return
        }
        groups = snapshot.groups
        savedAt = snapshot.savedAt
    }

    private func store() {
        guard !groups.isEmpty else { return }
        let snapshot = CloudSnapshot(savedAt: Date(), groups: groups)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.snapshotURL, options: .atomic)
        savedAt = snapshot.savedAt
    }

    private func load(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await NovelService().tagCloudGroups()
            error = nil
            store()
        } catch {
            if groups.isEmpty { self.error = error }
        }
    }
}
