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
    @State private var guide: DesktopParser.TagGuide?
    @State private var showsGuide = false
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
                    if guide != nil {
                        Button {
                            showsGuide = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.tint)
                                Text("检索服务相关说明和使用指南")
                                    .font(.subheadline.weight(.medium))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(cornerRadius: 22)
                        }
                        .buttonStyle(.plain)
                    }
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
        .sheet(isPresented: $showsGuide) {
            if let guide {
                TagGuideSheet(guide: guide)
            }
        }
    }

    // MARK: - Stored groups

    /// The cloud changes a few times a year, so it is kept between launches like the home
    /// screen's rows: paint what was stored, then refresh over it.
    private struct CloudSnapshot: Codable {
        var savedAt: Date
        var groups: [DesktopParser.TagGroup]
        var guide: DesktopParser.TagGuide?
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
        guide = snapshot.guide
        savedAt = snapshot.savedAt
    }

    private func store() {
        guard !groups.isEmpty else { return }
        let snapshot = CloudSnapshot(savedAt: Date(), groups: groups, guide: guide)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.snapshotURL, options: .atomic)
        savedAt = snapshot.savedAt
    }

    private func load(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await NovelService().tagCloudPage()
            groups = page.groups
            guide = page.guide
            error = nil
            store()
        } catch {
            if groups.isEmpty { self.error = error }
        }
    }
}


/// The site's explanation of its tags, shown as written.
struct TagGuideSheet: View {
    var guide: DesktopParser.TagGuide
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(guide.intro.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 22)

                    ForEach(guide.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.tag)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                            Text(entry.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 22)
                    }
                }
                .padding(18)
            }
            .background { AppBackground() }
            .navigationTitle("标签说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
