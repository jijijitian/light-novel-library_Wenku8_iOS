import SwiftUI
import Wenku8Core

/// Choose which volumes of a book to download.
///
/// The Android app offers the same thing as a multi-select dialog. Without it a long
/// series is all-or-nothing, so a reader who wants the first three volumes has to download
/// two hundred chapters.
struct VolumePickerSheet: View {
    var title: String
    var volumes: [Volume]
    /// Called with the chosen volume ids, or `nil` for "every volume".
    var onConfirm: (Set<String>?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    /// Volumes already stored, so the sheet can show what a selection would add.
    var storedChapterIDs: Set<Int> = []

    /// Volumes that still have something to fetch.
    ///
    /// A volume whose chapters are all stored has nothing to offer here, and listing it
    /// only asks the reader to skip past it. A partly stored volume stays, because the
    /// missing chapters are exactly what this sheet exists to fetch.
    private var available: [Volume] {
        volumes.filter { volume in
            !volume.chapters.allSatisfy { storedChapterIDs.contains($0.id) }
        }
    }

    private var allSelected: Bool {
        !available.isEmpty && selected.count == available.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selected = allSelected ? [] : Set(available.map(\.id))
                    } label: {
                        HStack {
                            Label(
                                allSelected ? "取消全选" : "全选",
                                systemImage: allSelected ? "checkmark.circle.fill" : "circle"
                            )
                            Spacer()
                            Text("\(available.count) 卷")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(available.isEmpty)
                } footer: {
                    Text("已选择 \(selected.count) 卷 · \(selectedChapterCount) 章")
                }

                Section {
                    if available.isEmpty {
                        Text("所有分卷都已下载完成")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(available) { volume in
                        Button {
                            toggle(volume.id)
                        } label: {
                            row(volume)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") {
                        // Everything selected is the common case; passing nil keeps the
                        // manifest identical to a plain full download.
                        onConfirm(allSelected ? nil : selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                if selected.isEmpty { selected = Set(available.map(\.id)) }
            }
        }
    }

    private func row(_ volume: Volume) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected.contains(volume.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected.contains(volume.id) ? AppTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(volume.chapters.count) 章" + storedSuffix(volume))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// Notes how much of a volume is already on disk, so a re-download is not surprising.
    private func storedSuffix(_ volume: Volume) -> String {
        let stored = volume.chapters.filter { storedChapterIDs.contains($0.id) }.count
        guard stored > 0 else { return "" }
        return stored == volume.chapters.count ? " · 已缓存" : " · 已有 \(stored) 章"
    }

    /// Chapters this selection would fetch, counting only what is missing in a partly
    /// stored volume.
    private var selectedChapterCount: Int {
        available
            .filter { selected.contains($0.id) }
            .reduce(0) { total, volume in
                total + volume.chapters.filter { !storedChapterIDs.contains($0.id) }.count
            }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
