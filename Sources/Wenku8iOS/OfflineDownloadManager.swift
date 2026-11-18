import Foundation
import Wenku8Core

/// Drives a book download and exposes its progress to the UI.
///
/// Kept separate from `OfflineStore` (which only touches disk) so the store stays
/// testable without a network, and so the download can be cancelled mid-book and
/// resumed later from whatever chapters already landed.
@MainActor
public final class OfflineDownloadManager: ObservableObject {
    public struct Progress: Equatable {
        public var novelID: Int
        public var completed: Int
        public var total: Int
        /// The book being downloaded. The chapter title changes constantly and identified
        /// nothing to the reader — the progress row showed a chapter name where a book
        /// name was expected.
        public var novelTitle: String
        /// Chapter currently in flight, shown as the detail line.
        public var currentChapterTitle: String

        public var fraction: Double {
            total > 0 ? Double(completed) / Double(total) : 0
        }
    }

    public static let shared = OfflineDownloadManager()

    @Published public private(set) var progress: Progress?
    @Published public private(set) var lastError: String?

    private let service: NovelService
    private let store: OfflineStore
    private var task: Task<Void, Never>?

    public init(service: NovelService = NovelService(), store: OfflineStore = .shared) {
        self.service = service
        self.store = store
    }

    public var isDownloading: Bool { progress != nil }

    public func isDownloading(_ aid: Int) -> Bool {
        progress?.novelID == aid
    }

    /// Downloads a whole book. Already-stored chapters are skipped, so calling
    /// this again resumes rather than restarting.
    public func download(novelID aid: Int) {
        guard !isDownloading else { return }
        lastError = nil
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(aid: aid)
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    private func run(aid: Int) async {
        do {
            let detail = try await service.detail(aid: aid)
            let volumes = try await service.volumes(aid: aid)
            let chapters = volumes.flatMap(\.chapters)
            guard !chapters.isEmpty else {
                lastError = "这本书没有可下载的章节"
                progress = nil
                return
            }

            // Cache the cover first: it is what the offline shelf shows.
            var coverFileName: String?
            if let cover = detail.coverURL,
               let data = try? await fetch(cover) {
                coverFileName = await store.saveCover(data, for: aid, remote: cover)
            }

            var entry = await store.makeEntry(detail: detail, volumes: volumes, coverFile: coverFileName)
            await store.saveManifest(entry)

            let missing = chapters.filter { !entry.storedChapterIDs.contains($0.id) }
            progress = Progress(
                novelID: aid,
                completed: entry.chapterIDs.count - missing.count,
                total: entry.chapterIDs.count,
                novelTitle: detail.title,
                currentChapterTitle: missing.first?.title ?? ""
            )

            for chapter in missing {
                if Task.isCancelled { break }
                progress?.currentChapterTitle = chapter.title
                do {
                    let content = try await service.chapter(aid: aid, cid: chapter.id)
                    await store.saveChapter(content, for: aid)
                    // Illustrations are part of the chapter, so fetch them too.
                    for case let .image(url) in content.blocks {
                        if let data = try? await fetch(url) {
                            await store.saveImage(data, for: aid, remote: url)
                        }
                    }
                    entry.storedChapterIDs.insert(chapter.id)
                    entry.updatedAt = Date()
                    await store.saveManifest(entry)
                } catch {
                    // A single failing chapter must not abort the whole book; it
                    // stays out of `storedChapterIDs` and is retried next time.
                    lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
                progress?.completed = entry.storedChapterIDs.count
            }

            entry.bytes = await store.usedBytes(for: aid)
            entry.updatedAt = Date()
            await store.saveManifest(entry)
            progress = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            progress = nil
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Illustration hosts accept plain requests, but the relay's own host
        // requires the client agent.
        if url.host?.contains("wenku8-relay") == true {
            request.setValue("okhttp/4.12.0", forHTTPHeaderField: "User-Agent")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    public func delete(_ aid: Int) async {
        await store.delete(aid)
    }
}
