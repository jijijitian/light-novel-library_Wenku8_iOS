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

    /// Reports that a chapter is being fetched outside the download queue.
    ///
    /// A delisted book's pack is fetched the moment a chapter is opened; without this the
    /// downloads page shows nothing while a multi-megabyte volume is on the wire.
    public func noteAutomaticVolumeFetch(novelID: Int, chapterID: Int) {
        guard progress == nil else { return }
        automaticBusyChapterID = chapterID
        // No chapter id here: the downloads page names the volume, and a chapter id would make
        // its row — and the chapter's own tick — report "downloading" for a chapter that is
        // merely being read.
        progress = Progress(
            novelID: novelID,
            completed: 0,
            total: 1,
            novelTitle: Self.automaticVolumeTitle,
            currentChapterTitle: "所在分卷",
            currentChapterID: nil
        )
    }

    /// The chapter whose volume an automatic fetch is running for, if any.
    ///
    /// Kept apart from `progress`, so the downloads page can name it without the catalogue
    /// treating the chapter as a queued download.
    @Published public private(set) var automaticBusyChapterID: Int?

    /// Ends an automatic volume fetch, leaving a short "finished" note behind.
    ///
    /// A volume download takes about two seconds, so clearing the row the moment it lands
    /// left the downloads page showing nothing at all — the work happened, and anybody who
    /// looked a second later would not know it had. The note stays just long enough to be
    /// seen, then clears itself.
    public func finishAutomaticVolumeFetch() {
        guard progress?.total == 1, progress?.novelTitle == Self.automaticVolumeTitle else { return }
        automaticBusyChapterID = nil
        automaticFinish = "已下载分卷"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                guard let self else { return }
                self.progress = nil
                self.automaticFinish = nil
                self.automaticBusyChapterID = nil
            }
        }
    }

    /// Shown briefly after an automatic fetch, so the work is visible.
    @Published public private(set) var automaticFinish: String?

    /// Prefix used for rows that describe an automatic fetch rather than a queued download.
    static let automaticVolumeTitle = "正在下载分卷"

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

            // A delisted book is fetched a whole volume at a time: the pack endpoint answers
            // with an entire volume, and one chapter's fetch stores all of its siblings. Asking
            // per chapter would then read the same volume from disk once per chapter, so the
            // loop below goes volume by volume for these books.
            if await service.isRestricted(aid) {
                await downloadDelisted(
                    aid: aid,
                    volumes: selected,
                    chapters: chapters,
                    entry: &entry
                )
                entry.bytes = await store.usedBytes(for: aid)
                entry.updatedAt = Date()
                await store.saveManifest(entry)
                progress = nil
                return
            }

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
                        // `saveChapter` writes the record too; this copy only feeds the
                        // progress count below.
                        entry.storedChapterIDs.insert(chapter.id)
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

    /// Downloads a delisted book one volume at a time.
    ///
    /// The pack endpoint hands back an entire volume, and the chapter fetch that reads it stores
    /// every chapter of that volume on the way through — pictures included. One request per
    /// volume is therefore enough, and asking again for each of its chapters only re-reads what
    /// was just written.
    private func downloadDelisted(
        aid: Int,
        volumes: [Volume],
        chapters: [ChapterLink],
        entry: inout OfflineStore.Entry
    ) async {
        for volume in volumes {
            if Task.isCancelled { break }
            let pending = volume.chapters.filter { !entry.storedChapterIDs.contains($0.id) }
            guard !pending.isEmpty else { continue }

            // Any chapter of the volume fetches the whole of it, so the first pending one is
            // asked for and the rest arrive with it.
            progress?.currentChapterTitle = pending[0].title
            progress?.currentChapterID = pending[0].id

            var fetched = false
            for attempt in 0..<2 where !fetched {
                do {
                    _ = try await service.chapter(aid: aid, cid: pending[0].id)
                    fetched = true
                } catch {
                    if attempt == 1 {
                        lastError = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    } else {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                }
            }
            guard fetched else { continue }

            // The volume wrote its own chapters; read back what it stored so the count reflects
            // reality rather than an assumption.
            if let refreshed = await store.entry(for: aid) { entry = refreshed }
            progress?.completed = chapters.filter { entry.storedChapterIDs.contains($0.id) }.count
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    public func delete(_ aid: Int) async {
        await store.delete(aid)
    }
}
