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

    private var allSelected: Bool {
        !volumes.isEmpty && selected.count == volumes.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selected = allSelected ? [] : Set(volumes.map(\.id))
                    } label: {
                        HStack {
                            Label(
                                allSelected ? "取消全选" : "全选",
                                systemImage: allSelected ? "checkmark.circle.fill" : "circle"
                            )
                            Spacer()
                            Text("\(volumes.count) 卷")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("已选择 \(selected.count) 卷 · \(selectedChapterCount) 章")
                }

                Section {
                    ForEach(volumes) { volume in
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
                if selected.isEmpty { selected = Set(volumes.map(\.id)) }
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

    private var selectedChapterCount: Int {
        volumes.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.chapters.count }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
