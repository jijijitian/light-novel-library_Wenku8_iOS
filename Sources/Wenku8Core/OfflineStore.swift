import Foundation
import Wenku8Core

/// Downloads whole books to disk so they read without a network.
///
/// Layout under `Application Support/Offline/`:
///
/// ```
/// <aid>/
///   manifest.json          book summary, chapter index, what is stored
///   chapters/<cid>.json    one `ChapterContent` per chapter
///   images/<hash>.img      illustration bytes, keyed by a hash of the URL
///   covers/<aid>.<ext>     the cover image
/// ```
///
/// Chapter bodies are stored as `ChapterContent` JSON, and illustrations are
/// fetched eagerly: an offline reader that only cached text would show the prose
/// with broken pictures, which is exactly the chapter type the relay serves for
/// these books.
public actor OfflineStore {
    public static let shared = OfflineStore()

    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var novelID: Int
        public var title: String
        public var author: String?
        public var chapterIDs: [Int]
        public var chapterTitles: [Int: String]
        public var storedChapterIDs: Set<Int>
        public var coverFile: String?
        public var updatedAt: Date
        public var bytes: Int64

        public var id: Int { novelID }
        public var progress: Double {
            guard !chapterIDs.isEmpty else { return 0 }
            return Double(storedChapterIDs.count) / Double(chapterIDs.count)
        }
        public var isComplete: Bool {
            !chapterIDs.isEmpty && storedChapterIDs.count >= chapterIDs.count
        }
    }

    /// Progress emitted while a download runs.
    public struct Progress: Sendable {
        public var completed: Int
        public var total: Int
        public var currentTitle: String
    }

    private let root: URL
    private let fileManager = FileManager.default

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = base.appendingPathComponent("Offline", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    private func directory(for aid: Int) -> URL {
        root.appendingPathComponent("\(aid)", isDirectory: true)
    }

    private func chaptersDirectory(for aid: Int) -> URL {
        directory(for: aid).appendingPathComponent("chapters", isDirectory: true)
    }

    private func imagesDirectory(for aid: Int) -> URL {
        directory(for: aid).appendingPathComponent("images", isDirectory: true)
    }

    private func manifestURL(for aid: Int) -> URL {
        directory(for: aid).appendingPathComponent("manifest.json")
    }

    private func chapterURL(for aid: Int, cid: Int) -> URL {
        chaptersDirectory(for: aid).appendingPathComponent("\(cid).json")
    }

    /// Illustration bytes are addressed by a stable hash of the source URL, so
    /// re-downloading the same chapter does not duplicate files.
    static func imageFileName(for url: URL) -> String {
        let digest = SHA256.hash(Array(url.absoluteString.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(hex).img"
    }

    public func imageURL(for aid: Int, remote: URL) -> URL? {
        let path = imagesDirectory(for: aid).appendingPathComponent(Self.imageFileName(for: remote))
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Reading

    public func entries() -> [Entry] {
        guard let dirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [Entry] = []
        for dir in dirs {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            result.append(entry)
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func entry(for aid: Int) -> Entry? {
        guard let data = try? Data(contentsOf: manifestURL(for: aid)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    public func hasChapter(_ aid: Int, cid: Int) -> Bool {
        fileManager.fileExists(atPath: chapterURL(for: aid, cid: cid).path)
    }

    /// Returns the stored chapter, or `nil` when it was never downloaded.
    public func chapter(_ aid: Int, cid: Int) -> ChapterContent? {
        guard let data = try? Data(contentsOf: chapterURL(for: aid, cid: cid)) else { return nil }
        return try? JSONDecoder().decode(ChapterContent.self, from: data)
    }

    public func coverURL(for aid: Int) -> URL? {
        guard let entry = entry(for: aid), let cover = entry.coverFile else { return nil }
        let url = directory(for: aid).appendingPathComponent(cover)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Writing

    public func saveChapter(_ content: ChapterContent, for aid: Int) {
        try? fileManager.createDirectory(at: chaptersDirectory(for: aid), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(content) else { return }
        try? data.write(to: chapterURL(for: aid, cid: content.chapterID), options: .atomic)
    }

    public func saveManifest(_ entry: Entry) {
        try? fileManager.createDirectory(at: directory(for: entry.novelID), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: manifestURL(for: entry.novelID), options: .atomic)
    }

    public func saveImage(_ data: Data, for aid: Int, remote: URL) {
        try? fileManager.createDirectory(at: imagesDirectory(for: aid), withIntermediateDirectories: true)
        let path = imagesDirectory(for: aid).appendingPathComponent(Self.imageFileName(for: remote))
        try? data.write(to: path, options: .atomic)
    }

    public func saveCover(_ data: Data, for aid: Int, remote: URL) -> String? {
        let ext = remote.pathExtension.isEmpty ? "jpg" : remote.pathExtension
        let name = "cover.\(ext)"
        let path = directory(for: aid).appendingPathComponent(name)
        try? fileManager.createDirectory(at: directory(for: aid), withIntermediateDirectories: true)
        guard (try? data.write(to: path, options: .atomic)) != nil else { return nil }
        return name
    }

    public func delete(_ aid: Int) {
        try? fileManager.removeItem(at: directory(for: aid))
    }

    /// Bytes currently used on disk by one book.
    public func usedBytes(for aid: Int) -> Int64 {
        Self.size(of: directory(for: aid), fileManager: fileManager)
    }

    public func totalBytes() -> Int64 {
        Self.size(of: root, fileManager: fileManager)
    }

    /// Removes every downloaded book.
    public func removeAll() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static func size(of url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Builds the manifest for a book that is about to be downloaded.
    public func makeEntry(
        detail: NovelDetail,
        volumes: [Volume],
        coverFile: String?
    ) -> Entry {
        let chapters = volumes.flatMap(\.chapters)
        var titles: [Int: String] = [:]
        for chapter in chapters { titles[chapter.id] = chapter.title }
        let existing = entry(for: detail.id)
        return Entry(
            novelID: detail.id,
            title: detail.title,
            author: detail.author.isEmpty ? nil : detail.author,
            chapterIDs: chapters.map(\.id),
            chapterTitles: titles,
            storedChapterIDs: existing?.storedChapterIDs ?? [],
            coverFile: coverFile ?? existing?.coverFile,
            updatedAt: Date(),
            bytes: usedBytes(for: detail.id)
        )
    }
}
