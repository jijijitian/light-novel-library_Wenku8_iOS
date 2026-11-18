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
        /// Id of the chapter in flight, so the catalogue can mark that exact row.
        public var currentChapterID: Int?

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

    public var isDownloading: Bool { progress != nil || startingNovelID != nil }

    /// Set the moment a download is requested, before the first request returns.
    ///
    /// The book's detail and catalogue are fetched before any chapter can be counted, and
    /// without this the button flipped back to "继续下载" for that second and then to
    /// "正在下载" again — it read as the tap having failed.
    @Published public private(set) var startingNovelID: Int?

    public func isDownloading(_ aid: Int) -> Bool {
        progress?.novelID == aid
    }

    /// Downloads a whole book. Already-stored chapters are skipped, so calling
    /// this again resumes rather than restarting.
    /// Downloads a book, optionally only some of its volumes.
    ///
    /// The Android app offers this as a multi-select of volumes, and it is the difference
    /// between "this book is 200 chapters" and "I want the first three volumes": a long
    /// series is otherwise an all-or-nothing download.
    ///
    /// - Parameter volumeIDs: volumes to fetch; `nil` means every volume.
    public func download(novelID aid: Int, volumeIDs: Set<String>? = nil) {
        guard !isDownloading else { return }
        lastError = nil
        // Published immediately so the UI switches on the tap, not on the first response.
        startingNovelID = aid
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(aid: aid, volumeIDs: volumeIDs)
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        progress = nil
        startingNovelID = nil
    }

    private func run(aid: Int, volumeIDs: Set<String>?) async {
        do {
            let detail = try await service.detail(aid: aid)
            let allVolumes = try await service.volumes(aid: aid)
            // A selected subset only limits what is fetched; the manifest keeps the whole
            // catalogue so the reader can still see the rest.
            let selected = volumeIDs.map { ids in
                allVolumes.filter { ids.contains($0.id) }
            } ?? allVolumes
            let chapters = selected.flatMap(\.chapters)
            guard !chapters.isEmpty else {
                lastError = "这本书没有可下载的章节"
                progress = nil
                startingNovelID = nil
                return
            }

            // Cache the cover first: it is what the offline shelf shows.
            var coverFileName: String?
            if let cover = detail.coverURL,
               let data = try? await fetch(cover) {
                coverFileName = await store.saveCover(data, for: aid, remote: cover)
            }

            var entry = await store.makeEntry(
                detail: detail,
                volumes: allVolumes,
                coverFile: coverFileName
            )
            await store.saveManifest(entry)

            let missing = chapters.filter { !entry.storedChapterIDs.contains($0.id) }
            // Progress describes what this download is fetching, not the whole catalogue:
            // choosing three volumes of twelve used to show "0/187" and then sit at a
            // fraction that never completed, because the denominator was every chapter.
            startingNovelID = nil
            progress = Progress(
                novelID: aid,
                completed: chapters.count - missing.count,
                total: chapters.count,
                novelTitle: detail.title,
                currentChapterTitle: missing.first?.title ?? "",
                currentChapterID: missing.first?.id
            )

            for chapter in missing {
                if Task.isCancelled { break }
                progress?.currentChapterTitle = chapter.title
                progress?.currentChapterID = chapter.id
                // Two attempts per chapter. The first request of a session pays the
                // cold-start cost and used to fail silently, leaving a hole in the book —
                // most visibly the first chapter, which then needed a second download.
                var stored = false
                for attempt in 0..<2 where !stored {
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
                        stored = true
                    } catch {
                        // A failing chapter must not abort the whole book. It stays out of
                        // `storedChapterIDs`, so it is retried next time — and once more
                        // here before giving up.
                        if attempt == 1 {
                            lastError = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                        } else {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                    }
                }
                // Counted against this download's own chapters for the same reason.
                progress?.completed = chapters.filter { entry.storedChapterIDs.contains($0.id) }.count
            }

            entry.bytes = await store.usedBytes(for: aid)
            entry.updatedAt = Date()
            await store.saveManifest(entry)
            progress = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            progress = nil
            startingNovelID = nil
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
