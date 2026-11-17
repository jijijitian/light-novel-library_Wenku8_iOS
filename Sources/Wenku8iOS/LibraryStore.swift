import Foundation
import SwiftUI
import Wenku8Core

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var saved: [NovelSummary] = []
    @Published private(set) var progress: [Int: ReadingProgress] = [:]
    @Published private(set) var history: [SearchHistoryEntry] = []

    private let defaults = UserDefaults.standard
    private let savedKey = "wenku8.saved"
    private let progressKey = "wenku8.progress"
    private let historyKey = "wenku8.history"
    private var loaded = false

    struct ReadingProgress: Codable, Hashable {
        var novelID: Int
        var chapterID: Int
        var chapterTitle: String
        var updated: Date
    }

    struct SearchHistoryEntry: Codable, Hashable, Identifiable {
        var keyword: String
        var field: String
        var date: Date

        var id: String { "\(field)|\(keyword)" }
    }

    init() {
        load()
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        saved = decode([NovelSummary].self, key: savedKey) ?? []
        progress = decode([Int: ReadingProgress].self, key: progressKey) ?? [:]
        history = decode([SearchHistoryEntry].self, key: historyKey) ?? []
    }

    func isSaved(_ id: Int) -> Bool {
        saved.contains { $0.id == id }
    }

    func toggle(_ novel: NovelSummary) {
        if let index = saved.firstIndex(where: { $0.id == novel.id }) {
            saved.remove(at: index)
        } else {
            saved.insert(novel, at: 0)
        }
        persist(saved, key: savedKey)
    }

    func add(_ novel: NovelSummary) {
        guard !isSaved(novel.id) else { return }
        saved.insert(novel, at: 0)
        persist(saved, key: savedKey)
    }

    func remove(_ id: Int) {
        saved.removeAll { $0.id == id }
        persist(saved, key: savedKey)
    }

    func progress(for novelID: Int) -> ReadingProgress? {
        progress[novelID]
    }

    func record(novelID: Int, chapterID: Int, chapterTitle: String) {
        progress[novelID] = ReadingProgress(
            novelID: novelID,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            updated: Date()
        )
        persist(progress, key: progressKey)
    }

    func remember(keyword: String, field: SearchQuery.Field) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.keyword == trimmed && $0.field == field.rawValue }
        history.insert(
            SearchHistoryEntry(keyword: trimmed, field: field.rawValue, date: Date()),
            at: 0
        )
        if history.count > 12 { history.removeLast(history.count - 12) }
        persist(history, key: historyKey)
    }

    func clearHistory() {
        history = []
        persist(history, key: historyKey)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
