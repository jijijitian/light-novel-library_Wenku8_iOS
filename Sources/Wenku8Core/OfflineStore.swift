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
        /// The book's detail record, exactly as the detail screen shows it — title,
        /// author, category, status, word count, intro, cover and recommendations. Stored
        /// whole rather than copied field by field: every field the screen renders has to
        /// survive, and a hand-picked subset silently loses whatever is added later.
        ///
        /// Optional so manifests written before this field still decode; a book without it
        /// falls back to the title and author above.
        public var detail: NovelDetail?

        /// The book's catalogue, kept with the metadata.
        ///
        /// A book that was only opened has no chapters on disk, and the catalogue is what
        /// the detail screen lists. Without it the offline page showed a book with no
        /// table of contents. Optional so older manifests still decode.
        public var volumes: [Volume]?

        public var id: Int { novelID }
        public var progress: Double {
            guard !chapterIDs.isEmpty else { return 0 }
            return Double(storedChapterIDs.count) / Double(chapterIDs.count)
        }
        public var isComplete: Bool {
            !chapterIDs.isEmpty && storedChapterIDs.count >= chapterIDs.count
        }

        /// Whether anything of this book is actually on disk to read.
        ///
        /// Metadata alone is not a download: a book opened once has its detail cached but
        /// no chapters, and reporting that as "partly downloaded" told the reader their
        /// book was half-fetched when nothing of it could be read offline.
        public var hasDownloadedChapters: Bool {
            !storedChapterIDs.isEmpty
        }

        /// Whether the shelf badge should report a state, and which.
        ///
        /// `nil` when there is nothing downloaded, so metadata-only books show no badge at
        /// all instead of a misleading one.
        public var downloadState: DownloadState? {
            guard hasDownloadedChapters, !chapterIDs.isEmpty else { return nil }
            return isComplete ? .complete : .partial
        }
    }

    /// What a book's download is, if it has one.
    public enum DownloadState: String, Codable, Sendable {
        case partial
        case complete
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

    /// Books that are actually downloaded, meaning something of them can be read offline.
    ///
    /// `entries()` returns every manifest, which includes books that were merely opened:
    /// their metadata is cached but no chapter is. Those belong on the metadata screen, not
    /// on a list of downloads, and showing them there implied a download that never
    /// happened.
    public func downloadedEntries() -> [Entry] {
        entries().filter(\.hasDownloadedChapters)
    }

    /// Every manifest, downloaded or metadata only.
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

    /// The stored cover file for a book, found on disk even when no manifest records it.
    ///
    /// Shelf books get their covers cached without a full download entry, so the manifest
    /// cannot be the only way to find them.
    public func storedCoverURL(for aid: Int) -> URL? {
        let dir = directory(for: aid)
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return nil }
        guard let name = names.first(where: { $0.hasPrefix("cover.") }) else { return nil }
        let url = dir.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func saveCover(_ data: Data, for aid: Int, remote: URL) -> String? {
        let ext = remote.pathExtension.isEmpty ? "jpg" : remote.pathExtension
        let name = "cover.\(ext)"
        let path = directory(for: aid).appendingPathComponent(name)
        try? fileManager.createDirectory(at: directory(for: aid), withIntermediateDirectories: true)
        guard (try? data.write(to: path, options: .atomic)) != nil else { return nil }
        return name
    }

    /// Removes some chapters of a book, leaving the rest and its metadata intact.
    ///
    /// Deleting a volume should free its space without taking the whole book: the reader
    /// is managing storage, not throwing the book away.
    @discardableResult
    public func deleteChapters(_ chapterIDs: Set<Int>, for aid: Int) -> Int {
        guard var entry = entry(for: aid) else { return 0 }
        var removed = 0
        for cid in chapterIDs where entry.storedChapterIDs.contains(cid) {
            if (try? fileManager.removeItem(at: chapterURL(for: aid, cid: cid))) != nil {
                removed += 1
            }
            entry.storedChapterIDs.remove(cid)
        }
        guard removed > 0 else { return 0 }
        entry.updatedAt = Date()
        entry.bytes = usedBytes(for: aid)
        saveManifest(entry)
        return removed
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

    /// Updates the stored detail for a book that is already cached.
    ///
    /// Only the metadata is replaced: the chapter list, stored chapters and byte count
    /// describe what is actually on disk and must not be touched by a refresh.
    public func refreshDetail(_ detail: NovelDetail) async {
        // A book that was only opened has no entry yet, and returning early there meant
        // opening a book never cached anything — the metadata list stayed empty however
        // many books were visited.
        guard var entry = entry(for: detail.id) else {
            cacheMetadata(detail)
            return
        }
        entry.detail = detail
        entry.title = detail.title
        entry.author = detail.author.isEmpty ? nil : detail.author
        entry.updatedAt = Date()
        saveManifest(entry)
    }

    /// Caches only a book's metadata, without downloading any chapter.
    ///
    /// Shelf books get this treatment so their detail pages and covers render offline even
    /// when the reader has not downloaded them.
    public func cacheMetadata(_ detail: NovelDetail, coverFile: String? = nil) {
        if var entry = entry(for: detail.id) {
            entry.detail = detail
            entry.title = detail.title
            entry.author = detail.author.isEmpty ? nil : detail.author
            if let coverFile { entry.coverFile = coverFile }
            entry.updatedAt = Date()
            saveManifest(entry)
            return
        }
        saveManifest(Entry(
            novelID: detail.id,
            title: detail.title,
            author: detail.author.isEmpty ? nil : detail.author,
            chapterIDs: [],
            chapterTitles: [:],
            storedChapterIDs: [],
            coverFile: coverFile,
            updatedAt: Date(),
            bytes: 0,
            detail: detail
        ))
    }

    /// Books whose metadata is cached but which have no downloaded chapters.
    public func metadataOnlyEntries() -> [Entry] {
        entries().filter { $0.chapterIDs.isEmpty && $0.detail != nil }
    }

    /// Records the cover file for a book that already has a manifest.
    public func attachCover(_ coverFile: String?, for aid: Int) async {
        guard let coverFile, var entry = entry(for: aid) else { return }
        entry.coverFile = coverFile
        saveManifest(entry)
    }

    /// Stores a book's catalogue with its metadata.
    public func cacheVolumes(_ volumes: [Volume], for aid: Int) async {
        guard var entry = entry(for: aid) else { return }
        entry.volumes = volumes
        // Keep the flat chapter list in step so progress and downloads still work.
        let chapters = volumes.flatMap(\.chapters)
        if entry.chapterIDs.isEmpty {
            entry.chapterIDs = chapters.map(\.id)
            var titles: [Int: String] = [:]
            for chapter in chapters { titles[chapter.id] = chapter.title }
            entry.chapterTitles = titles
        }
        entry.updatedAt = Date()
        saveManifest(entry)
    }

    /// The stored catalogue for a book, when one was cached.
    public func cachedVolumes(for aid: Int) -> [Volume]? {
        guard let entry = entry(for: aid), let volumes = entry.volumes else { return nil }
        return volumes.isEmpty ? nil : volumes
    }

    /// Removes the metadata for a book while leaving its chapters alone.
    public func dropDetail(for novelID: Int) {
        guard var entry = entry(for: novelID) else { return }
        entry.detail = nil
        saveManifest(entry)
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
        // Every field the manifest already holds has to be carried over: this value
        // replaces the manifest wholesale, so anything omitted is deleted. The catalogue
        // was missing here, and starting a download wiped the cached one.
        var entry = Entry(
            novelID: detail.id,
            title: detail.title,
            author: detail.author.isEmpty ? nil : detail.author,
            chapterIDs: chapters.map(\.id),
            chapterTitles: titles,
            storedChapterIDs: existing?.storedChapterIDs ?? [],
            coverFile: coverFile ?? existing?.coverFile,
            updatedAt: Date(),
            bytes: usedBytes(for: detail.id),
            detail: detail
        )
        // A partial download passes the full catalogue; a re-download that somehow has
        // none keeps whatever was stored rather than clearing it.
        entry.volumes = volumes.isEmpty ? existing?.volumes : volumes
        return entry
    }
}
