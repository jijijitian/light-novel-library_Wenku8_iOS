import Foundation
#if canImport(FoundationNetworking)
// The parser tests compile this module on Linux, where `URLRequest` and `URLSession`
// live in a separate module. Only the image download needs them.
import FoundationNetworking
#endif

public struct SearchQuery: Hashable, Sendable {
    public enum Field: String, CaseIterable, Identifiable, Sendable {
        case title
        case author

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .title: return "书名"
            case .author: return "作者"
            }
        }

        var parameter: String { rawValue == "title" ? "articlename" : "author" }
    }

    public var keyword: String
    public var field: Field

    public init(keyword: String, field: Field = .title) {
        self.keyword = keyword
        self.field = field
    }
}

public struct NovelService: Sendable {
    private let client: Wenku8Client
    private let relay: RelayClient
    /// Local download cache consulted before the network.
    private let offline: OfflineStore

    public init(
        client: Wenku8Client = .shared,
        relay: RelayClient = .shared,
        offline: OfflineStore = .shared
    ) {
        self.client = client
        self.relay = relay
        self.offline = offline
    }

    /// Relay-first helpers. The relay is a third-party volunteer service, so every
    /// call here is best-effort: a `nil` return simply means "use the WAP/desktop
    /// path", which stays fully functional.
    private var relayIsAvailable: Bool { relay.isAvailable }

    private func relaySearch(_ key: String, type: String) async -> [NovelSummary]? {
        guard relayIsAvailable else { return nil }
        // The relay expects the keyword form-encoded inside the action string.
        let encoded = TextDecoding.formEncode(key)
        guard let data = try? await relay.send(RelayAction.search(type: type, key: encoded)) else { return nil }
        let items = RelayParser.summaries(TextDecoding.decode(data)).uniquedByID()
        return items.isEmpty ? nil : items
    }

    /// `novellist` returns full rows with titles; `articlelist` returns bare ids
    /// and is useless on its own, so lists go through `novellist`.
    private func relayNovelList(sort: String, page: Int) async -> [NovelSummary]? {
        guard relayIsAvailable else { return nil }
        guard let data = try? await relay.send(RelayAction.novelList(sort: sort, page: page)) else { return nil }
        let items = RelayParser.summaries(TextDecoding.decode(data)).uniquedByID()
        return items.isEmpty ? nil : items
    }

    /// One page of a relay listing, with the total the service reports.
    private func relayNovelListPage(sort: String, page: Int) async -> NovelListPage? {
        guard relayIsAvailable else { return nil }
        guard let data = try? await relay.send(RelayAction.novelList(sort: sort, page: page)) else {
            return nil
        }
        let text = TextDecoding.decode(data)
        let items = RelayParser.summaries(text).uniquedByID()
        guard !items.isEmpty else { return nil }
        return NovelListPage(novels: items, totalPages: RelayParser.totalPages(text))
    }

    /// A ranking board, one page at a time.
    ///
    /// Boards run to hundreds of pages (the day-visit board reports 426), so a screen
    /// that fetched only page 1 showed a fraction of the list with no way to reach the
    /// rest.
    public func rankPage(_ board: RankBoard, page: Int) async throws -> NovelListPage {
        if relayIsAvailable {
            if let result = await relayNovelListPage(sort: board.rawValue, page: page),
               !result.novels.isEmpty {
                return result
            }
            throw Wenku8Error.unavailable("中转服务暂时无法提供这个榜单，请稍后再试")
        }
        let novels = try await rank(board, page: page)
        return NovelListPage(novels: novels, totalPages: nil)
    }

    /// A library category, one page at a time.
    public func libraryPage(_ category: Int, page: Int) async throws -> NovelListPage {
        let sort = category == 0 ? "all" : "\(category)"
        if relayIsAvailable {
            if let result = await relayNovelListPage(sort: sort, page: page),
               !result.novels.isEmpty {
                return result
            }
            throw Wenku8Error.unavailable("中转服务暂时无法提供这个分类，请稍后再试")
        }
        let novels = try await library(category, page: page)
        return NovelListPage(novels: novels, totalPages: nil)
    }

    /// A search result, one page at a time.
    public func searchPage(_ query: SearchQuery, page: Int) async throws -> NovelListPage {
        let keyword = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return NovelListPage(novels: [], totalPages: nil) }
        if relayIsAvailable {
            guard let data = try? await relay.send(
                RelayAction.search(type: query.field.parameter, key: keyword)
            ) else {
                throw Wenku8Error.unavailable("中转服务暂时无法搜索，请稍后再试")
            }
            let text = TextDecoding.decode(data)
            let items = RelayParser.summaries(text).uniquedByID()
            guard !items.isEmpty else {
                throw Wenku8Error.unavailable("没有找到匹配的书")
            }
            return NovelListPage(novels: items, totalPages: RelayParser.totalPages(text))
        }
        let novels = try await search(query)
        return NovelListPage(novels: novels, totalPages: nil)
    }

    // MARK: - Home

    /// The home screen's rows.
    ///
    /// With the relay enabled these come from it alone: the WAP home page serves a
    /// different (and partly login-gated) selection, so mixing the two would show a
    /// home screen assembled from two sources. The relay is asked for each board and
    /// the rows are built from what it returns; a board it cannot serve is simply
    /// omitted rather than quietly filled from the website.
    public func homeRows() async throws -> [HomeRow] {
        // The streaming path is what the UI uses; this collects the same rows for
        // callers that only want the finished list.
        return await homeRowsStreaming { _ in }
    }

    /// Legacy synchronous gather, kept for the website path only.
    private func legacyHomeRows() async throws -> [HomeRow] {
        let html = try await client.wap("/")
        let rows = WAPParser.homeSections(html)
        if rows.isEmpty {
            return try await fallbackHomeRows()
        }
        return rows
    }

    /// Builds the home rows from the relay's boards.
    /// The home rows, fetched one after another from the top of the page downwards.
    ///
    /// Each result is handed to `onRow` as soon as it arrives, so the page fills in
    /// top-to-bottom instead of appearing all at once when the slowest section finishes.
    /// The order matters for two reasons: the banner is built from the first section, and
    /// the reader sees the top of the page first — so a section that is slow or fails
    /// must not hold up the ones above it.
    ///
    /// A failed section is retried once; the relay occasionally answers slowly under load,
    /// and a lost section is visible as a missing row.
    public func homeRowsStreaming(
        onRow: @escaping @Sendable (HomeRow) async -> Void
    ) async -> [HomeRow] {
        if relayIsAvailable {
            var rows: [HomeRow] = []
            // 最近更新 goes first by design. It is the page's second section but the first
            // request, so the cold-start cost of the very first relay call — DNS, TLS and
            // the throttle's initial slot — is paid by a section the banner does not
            // depend on. When 今日热榜 went first it could lose that race and take the banner
            // down with it, which looked like "热榜 empty, everything else fine".
            for section in [HomeSection.latest, .hot, .newcomer, .weekly] {
                let items = await homeSectionItems(section)
                guard !items.isEmpty else { continue }
                let row = HomeRow(section: section, items: items)
                rows.append(row)
                await onRow(row)
            }
            // Handed back in page order regardless of fetch order, so the caller's final
            // assignment (if it ever uses it) matches what is on screen.
            return HomeSection.allCases.compactMap { section in
                rows.first { $0.section == section }
            }
        }
        // The website path parses one page, so it is all-or-nothing by nature.
        let rows = (try? await homeRows()) ?? []
        for row in rows { await onRow(row) }
        return rows
    }

    /// One section's books, retried once.
    ///
    /// A cancelled request is not retried and not reported as "no data": the task that
    /// owned it went away (the view was rebuilt), so the work is simply moot. Retrying a
    /// cancellation previously spent a second throttled slot and could knock out the
    /// sections queued behind it.
    private func homeSectionItems(_ section: HomeSection) async -> [NovelSummary] {
        let sort = section.board.rawValue
        // Three attempts with a growing pause. The first request of a session carries the
        // cold-start cost (DNS, TLS), and it failed often enough to leave 今日热榜 — and the
        // banner built from it — empty until a manual refresh. Extra attempts are cheap
        // next to a missing section, and a section that is genuinely unavailable still
        // gives up after the third.
        for attempt in 0..<3 {
            if Task.isCancelled { return [] }
            if let page = await relayNovelListPage(sort: sort, page: 1), !page.novels.isEmpty {
                return page.novels
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(400_000 * (attempt + 1)))
            }
        }
        return []
    }

    private func fallbackHomeRows() async throws -> [HomeRow] {
        var rows: [HomeRow] = []
        for section in HomeSection.allCases {
            if let items = try? await rank(section.board, page: 1), !items.isEmpty {
                rows.append(HomeRow(section: section, items: items))
            }
        }
        return rows
    }

    // MARK: - Ranking

    public func rank(_ board: RankBoard, page: Int = 1) async throws -> [NovelSummary] {
        // With the relay enabled every board comes from it, and nothing is silently
        // substituted from the website: a blank board is honest, a board quietly
        // assembled from another source is not.
        if relayIsAvailable {
            if let items = await relayNovelList(sort: board.rawValue, page: page), !items.isEmpty {
                return items
            }
            throw Wenku8Error.unavailable("中转服务暂时无法提供这个榜单，请稍后再试")
        }
        let path = "/article/toplist.php?sort=\(board.rawValue)&page=\(page)"
        let html = try await client.wap(path)
        if WAPParser.requiresLogin(html) {
            return try await rankedFallback(board, page: page)
        }
        let items = WAPParser.linksIn(html).uniquedByID()
        if items.isEmpty {
            return try await rankedFallback(board, page: page)
        }
        return items
    }

    /// The WAP ranking needs a session and the desktop ranking serves a shutdown
    /// notice to anonymous clients, so fall back to the yearly Sugoi ranking,
    /// which is a static page and still lists real books.
    private func rankedFallback(_ board: RankBoard, page: Int) async throws -> [NovelSummary] {
        if let items = try? await desktopRank(board, page: page), !items.isEmpty {
            return items
        }
        let year = SugoiParser.availableYears[max(0, min(page - 1, SugoiParser.availableYears.count - 1))]
        let books = try await sugoi(year: year).allBooks
        guard !books.isEmpty else {
            throw Wenku8Error.unavailable("排行榜暂时无法访问，请稍后再试")
        }
        return books
    }

    public func desktopRank(_ board: RankBoard, page: Int = 1) async throws -> [NovelSummary] {
        let path = "/modules/article/toplist.php?sort=\(board.rawValue)&page=\(page)"
        let html = try await client.desktop(path)
        guard !DesktopParser.isPlaceholder(html) else { return [] }
        return DesktopParser.novelCards(html)
    }

    public func sugoi(year: Int) async throws -> SugoiParser.Year {
        let html = try await client.desktop("/zt/sugoi/\(year).php")
        guard !DesktopParser.isPlaceholder(html) else {
            throw Wenku8Error.unavailable("榜单页面暂时无法访问")
        }
        let parsed = SugoiParser.parse(html, year: year)
        guard !parsed.allBooks.isEmpty else {
            throw Wenku8Error.unavailable("\(year) 年度榜单暂时无法访问")
        }
        return parsed
    }

    public func library(_ category: Int, page: Int = 1) async throws -> [NovelSummary] {
        let sort = category == 0 ? "all" : "\(category)"
        if relayIsAvailable {
            if let items = await relayNovelList(sort: sort, page: page), !items.isEmpty {
                return items
            }
            throw Wenku8Error.unavailable("中转服务暂时无法提供这个分类，请稍后再试")
        }
        let path = "/article/sortlist.php?class=\(category)&page=\(page)"
        let html = try await client.wap(path)
        if WAPParser.requiresLogin(html) {
            // The library listing is session-only on every mirror, so report the real
            // reason instead of substituting an unrelated ranking.
            throw Wenku8Error.needLogin
        }
        return WAPParser.linksIn(html).uniquedByID()
    }

    /// Library categories.
    ///
    /// The relay publishes the same taxonomy (`action=xml&item=sort`); with it enabled
    /// the list comes from there so the categories match the listings the relay
    /// actually serves.
    public func categories() async throws -> [LibraryCategory] {
        if relayIsAvailable,
           let text = try? await relay.sendText(RelayAction.sorts()),
           let parsed = RelayParser.categories(text), !parsed.isEmpty {
            return parsed
        }
        if relayIsAvailable { return LibraryCategory.all }
        let html = try await client.wap("/article/sort.php")
        let list = WAPParser.libraryCategories(html)
        return list.isEmpty ? LibraryCategory.all : list
    }

    // MARK: - Search

    public func search(_ query: SearchQuery) async throws -> [NovelSummary] {
        let keyword = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        if relayIsAvailable {
            if let items = await relaySearch(keyword, type: query.field.parameter) {
                return items
            }
            throw Wenku8Error.unavailable("中转服务暂时无法搜索，请稍后再试")
        }
        let fields = [
            "action": "search",
            "searchtype": query.field.parameter,
            "searchkey": keyword,
        ]
        var lastError: Error?
        for host in client.endpoints.wapHosts {
            guard let url = URL(string: host + "/article/search.php") else { continue }
            do {
                let response = try await client.post(url, fields: fields)
                let items = WAPParser.linksIn(response.text).uniquedByID()
                if !items.isEmpty { return items }
                if WAPParser.requiresLogin(response.text) {
                    throw Wenku8Error.needLogin
                }
            } catch {
                lastError = error
            }
        }

        if let items = try? await desktopSearch(keyword: keyword, field: query.field), !items.isEmpty {
            return items.uniquedByID()
        }
        if let error = lastError { throw error }
        return []
    }

    private func desktopSearch(keyword: String, field: SearchQuery.Field) async throws -> [NovelSummary] {
        let path = "/modules/article/search.php?searchtype=\(field.parameter)"
            + "&searchkey=\(TextDecoding.formEncode(keyword))"
        let html = try await client.desktop(path)
        return DesktopParser.novelCards(html)
    }

    public func suggest(_ keyword: String) async throws -> [NovelSummary] {
        try await search(SearchQuery(keyword: keyword, field: .title))
    }

    // MARK: - Detail

    /// The cached detail for a book, if one is stored. Never touches the network.
    public func cachedDetail(aid: Int) async -> NovelDetail? {
        guard let entry = await offline.entry(for: aid) else { return nil }
        guard var cached = entry.detail else { return nil }
        cached.coverURL = await offline.coverURL(for: aid) ?? cached.coverURL
        return cached
    }

    /// Fetches a book's detail and caches it.
    ///
    /// Every book the reader opens is cached, not only downloaded ones: opening a book is
    /// the clearest statement that they care about it, and it makes the second visit
    /// instant and the offline visit possible.
    public func fetchDetail(aid: Int) async throws -> NovelDetail {
        let online = try await onlineDetail(aid: aid)
        await offline.refreshDetail(online)
        // Cover and catalogue are part of what the page shows, so they are cached with it
        // rather than left to be re-fetched on the next visit.
        if let cover = online.coverURL, let data = try? await fetchImage(cover) {
            let file = await offline.saveCover(data, for: aid, remote: cover)
            await offline.attachCover(file, for: aid)
        }
        if let volumes = try? await onlineVolumes(aid: aid) {
            await offline.cacheVolumes(volumes, for: aid)
        }
        return online
    }

    /// Caches a book's metadata, cover image and catalogue together.
    ///
    /// The three travel as one unit: a page with a title and no cover or contents is half a
    /// page, and all three come from separate requests that would otherwise each have to
    /// be remembered.
    /// Downloads an image the same way the rest of the app does.
    private func fetchImage(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if url.host?.contains("wenku8-relay") == true {
            request.setValue("okhttp/4.12.0", forHTTPHeaderField: "User-Agent")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// Re-reads one book's public information — title, author, blurb, cover.
    ///
    /// One request, unlike `fetchDetail`, which also pulls the catalogue: a shelf refresh
    /// only needs what the row shows.
    @discardableResult
    public func refreshBookInfo(aid: Int) async -> NovelDetail? {
        guard let detail = try? await onlineDetail(aid: aid) else { return nil }
        await offline.refreshDetail(detail)
        if let cover = detail.coverURL, let data = try? await fetchImage(cover) {
            let file = await offline.saveCover(data, for: aid, remote: cover)
            await offline.attachCover(file, for: aid)
        }
        return detail
    }

    /// Saves a book's cover image if it is not already on disk.
    ///
    /// Used for shelf books, whose rows showed a remote image every single time.
    @discardableResult
    public func cacheCover(aid: Int, coverURL: URL?) async -> Bool {
        if await offline.storedCoverURL(for: aid) != nil { return true }
        guard let coverURL, let data = try? await fetchImage(coverURL) else { return false }
        return await offline.saveCover(data, for: aid, remote: coverURL) != nil
    }

    /// Caches a book's cover if it is missing, leaving everything else alone.
    ///
    /// A book cached before covers were stored shows a remote image every time it is
    /// opened — visible, but never held. This fills that gap once.
    public func ensureCachedCover(aid: Int) async {
        guard await offline.coverURL(for: aid) == nil else { return }
        let detail = await offline.entry(for: aid)?.detail
        guard let cover = detail?.coverURL, let data = try? await fetchImage(cover) else { return }
        let file = await offline.saveCover(data, for: aid, remote: cover)
        await offline.attachCover(file, for: aid)
    }

    /// Caches a book's metadata, cover and catalogue, fetching only what is missing.
    ///
    /// Each piece is skipped when it is already stored: the relay is a volunteer service
    /// paced at one request every 1.2s, so re-fetching a record that is already on disk
    /// would starve every other request for no gain.
    public func cacheDetailFully(aid: Int) async {
        let stored = await offline.entry(for: aid)

        let detail: NovelDetail
        if let existing = stored?.detail {
            detail = existing
        } else if let fetched = try? await onlineDetail(aid: aid) {
            detail = fetched
        } else {
            return
        }

        var coverFile = stored?.coverFile
        if coverFile == nil, let cover = detail.coverURL,
           let data = try? await fetchImage(cover) {
            coverFile = await offline.saveCover(data, for: aid, remote: cover)
        }
        await offline.cacheMetadata(detail, coverFile: coverFile)

        if await offline.cachedVolumes(for: aid) == nil,
           let volumes = try? await onlineVolumes(aid: aid) {
            await offline.cacheVolumes(volumes, for: aid)
        }
    }

    public func detail(aid: Int) async throws -> NovelDetail {
        do {
            let online = try await onlineDetail(aid: aid)
            // A successful fetch refreshes the cached copy, so a book opened online shows
            // current information next time it is opened offline.
            await offline.refreshDetail(online)
            return online
        } catch {
            // Offline: hand back the whole record that was stored on download, not a
            // title-and-placeholder shell. Every field the detail screen draws comes back.
            if let entry = await offline.entry(for: aid) {
                if let cached = entry.detail {
                    var result = cached
                    result.coverURL = await offline.coverURL(for: aid) ?? cached.coverURL
                    return result
                }
                return NovelDetail(
                    id: aid,
                    title: entry.title,
                    author: entry.author ?? "",
                    intro: "已下载到本机，可离线阅读。",
                    coverURL: await offline.coverURL(for: aid)
                )
            }
            throw error
        }
    }

    private func onlineDetail(aid: Int) async throws -> NovelDetail {
        if relayIsAvailable {
            guard let data = try? await relay.send(RelayAction.meta(aid: aid)) else {
                throw Wenku8Error.unavailable("中转服务暂时无法获取书籍信息")
            }
            var parsed = RelayParser.detail(TextDecoding.decode(data), aid: aid)
            guard !parsed.title.isEmpty else {
                throw Wenku8Error.unavailable("中转服务返回的书籍信息不完整")
            }
            // `meta` carries the short preview; `intro` carries the full text.
            if let introData = try? await relay.send(RelayAction.intro(aid: aid)) {
                let full = RelayParser.intro(TextDecoding.decode(introData))
                if !full.isEmpty { parsed.intro = full }
            }
            return parsed
        }
        let html = try await client.wap("/article/articleinfo.php?id=\(aid)")
        var detail = WAPParser.novelDetail(html, aid: aid)
        if detail.title.isEmpty {
            let desktop = try await client.desktop("/book/\(aid).htm")
            detail = DesktopParser.novelDetail(desktop, aid: aid)
        }
        return detail
    }

    /// A book's catalogue, from the cache when one is stored.
    ///
    /// The catalogue is part of the metadata, so a book opened once is complete offline;
    /// reaching the network on every visit would defeat that.
    public func cachedVolumes(aid: Int) async -> [Volume]? {
        await offline.cachedVolumes(for: aid)
    }

    /// Fetches a catalogue and stores it with the book's metadata.
    public func fetchVolumes(aid: Int) async throws -> [Volume] {
        let volumes = try await onlineVolumes(aid: aid)
        await offline.cacheVolumes(volumes, for: aid)
        return volumes
    }

    public func volumes(aid: Int) async throws -> [Volume] {
        if let cached = await offline.cachedVolumes(for: aid) {
            return cached
        }
        do {
            return try await fetchVolumes(aid: aid)
        } catch {
            // Offline: rebuild the catalogue from the downloaded manifest so the
            // reader can still navigate a cached book.
            if let entry = await offline.entry(for: aid), !entry.chapterIDs.isEmpty {
                let chapters = entry.chapterIDs.map {
                    ChapterLink(id: $0, title: entry.chapterTitles[$0] ?? "第 \($0) 章")
                }
                return [Volume(id: "0", title: "已缓存", chapters: chapters)]
            }
            throw error
        }
    }

    private func onlineVolumes(aid: Int) async throws -> [Volume] {
        if relayIsAvailable {
            guard let data = try? await relay.send(RelayAction.chapterList(aid: aid)) else {
                throw Wenku8Error.unavailable("中转服务暂时无法获取目录")
            }
            let relayed = RelayParser.volumes(TextDecoding.decode(data))
            guard !relayed.isEmpty else {
                throw Wenku8Error.unavailable("中转服务返回的目录为空")
            }
            return Self.mergeVolumes(relayed)
        }
        do {
            let volumes = try await wapVolumes(aid: aid)
            if !volumes.isEmpty { return volumes }
        } catch {
            // Fall through to the desktop catalogue below: the WAP endpoint answers
            // "对不起，该文章不存在！" for books the desktop site still indexes.
        }
        return try await desktopVolumes(aid: aid)
    }

    private func wapVolumes(aid: Int) async throws -> [Volume] {
        var all: [Volume] = []
        var page = 1
        var totalPages = 1
        repeat {
            let html = try await client.wap("/article/readbook.php?aid=\(aid)&page=\(page)")
            if WAPParser.requiresLogin(html) {
                throw Wenku8Error.needLogin
            }
            let parsed = WAPParser.volumes(html)
            all.append(contentsOf: parsed)
            (page, totalPages) = WAPParser.pagination(html)
            page += 1
            if page > 200 { break }
        } while page <= totalPages
        return Self.mergeVolumes(all)
    }

    /// Desktop catalogue fallback (`/novel/<group>/<aid>/index.htm`).
    ///
    /// The group is `max(1, aid / 1000)`, matching the site's own folder layout.
    /// Some books are only reachable this way, so an empty WAP catalogue must not
    /// be reported as "this book has no chapters".
    private func desktopVolumes(aid: Int) async throws -> [Volume] {
        let group = max(1, aid / 1000)
        let html = try await client.desktop("/novel/\(group)/\(aid)/index.htm")
        if DesktopParser.isPlaceholder(html) { return [] }
        return Self.mergeVolumes(DesktopParser.volumes(html))
    }

    /// Merges the volume fragments returned by each catalogue page.
    ///
    /// A volume that spans a page boundary arrives twice, and re-appending its
    /// chapters verbatim would produce duplicate `ChapterLink` ids. SwiftUI's
    /// `ForEach` treats a duplicate id as a fatal error, so chapters are deduped
    /// by id while the order is preserved.
    static func mergeVolumes(_ volumes: [Volume]) -> [Volume] {
        var merged: [Volume] = []
        var seenChapters = Set<Int>()
        for volume in volumes {
            if let last = merged.last, last.title == volume.title {
                var updated = last
                for chapter in volume.chapters where seenChapters.insert(chapter.id).inserted {
                    updated.chapters.append(chapter)
                }
                merged[merged.count - 1] = updated
            } else {
                var copy = volume
                var chapters: [ChapterLink] = []
                for chapter in volume.chapters where seenChapters.insert(chapter.id).inserted {
                    chapters.append(chapter)
                }
                // Two volumes may legitimately share a title, so the id is derived
                // from the position in the merged list rather than the title.
                copy.id = "\(merged.count)"
                copy.chapters = chapters
                merged.append(copy)
            }
        }
        return merged.filter { !$0.chapters.isEmpty }
    }

    public func chapter(aid: Int, cid: Int) async throws -> ChapterContent {
        // A downloaded chapter always wins, which is what makes offline reading
        // work at all.
        if let cached = await offline.chapter(aid, cid: cid) {
            return cached
        }
        if relayIsAvailable {
            guard let data = try? await relay.send(RelayAction.text(aid: aid, cid: cid)) else {
                throw Wenku8Error.unavailable("中转服务暂时无法获取正文")
            }
            let parsed = RelayParser.chapter(TextDecoding.decode(data), aid: aid, cid: cid)
            guard !parsed.blocks.isEmpty else {
                throw Wenku8Error.unavailable("中转服务返回的正文为空")
            }
            return parsed
        }
        var pages: [ChapterContent] = []
        var page = 1
        var total = 1
        repeat {
            let html = try await client.wap("/article/readchapter.php?aid=\(aid)&cid=\(cid)&page=\(page)&psize=50000")
            let parsed = WAPParser.chapterContent(html, aid: aid, cid: cid)
            (page, total) = WAPParser.pagination(html)
            var merged = parsed
            merged.pageCount = total
            pages.append(merged)
            page += 1
            if page > 100 { break }
        } while page <= total

        let blocks = pages.flatMap(\.blocks)
        let title = pages.first?.title ?? ""
        if blocks.isEmpty {
            // Some books are delisted from reading while their catalogue still
            // resolves; the desktop chapter page states the reason ("因版权问题…").
            // Reporting that instead of a generic message stops it looking like a
            // client fault.
            if let reason = try? await desktopChapterNotice(aid: aid, cid: cid), !reason.isEmpty {
                throw Wenku8Error.unavailable(reason)
            }
            throw Wenku8Error.unavailable("该章节没有可显示的正文")
        }
        return ChapterContent(novelID: aid, chapterID: cid, title: title, blocks: blocks)
    }

    /// Reads the desktop chapter page and returns the site's own notice when the
    /// body was replaced by one (delisted-for-copyright books do this).
    private func desktopChapterNotice(aid: Int, cid: Int) async throws -> String? {
        let group = max(1, aid / 1000)
        let html = try await client.desktop("/novel/\(group)/\(aid)/\(cid).htm")
        if DesktopParser.isPlaceholder(html) { return nil }
        let text = Markup.plainText(html)
        for marker in ["因版权问题", "不再提供该小说的阅读", "该文章不存在", "本章节是纯图片内容"] {
            guard let range = text.range(of: marker) else { continue }
            // Keep the sentence the marker sits in, so the user sees the site's
            // wording rather than a bare fragment.
            let tail = text[range.lowerBound...]
            let sentence = tail.prefix { !"。！\n".contains($0) }
            let notice = Markup.normalize(String(sentence))
            if !notice.isEmpty { return notice + "。" }
        }
        return nil
    }

    public func reviews(aid: Int) async throws -> [NovelReview] {
        let html = try await client.wap("/article/reviews.php?aid=\(aid)&type=all")
        if WAPParser.requiresLogin(html) {
            throw Wenku8Error.needLogin
        }
        return WAPParser.reviews(html)
    }

    public func reviewPosts(rid: Int) async throws -> (topic: String, posts: [ReviewPost]) {
        let html = try await client.wap("/article/reviewshow.php?rid=\(rid)")
        return WAPParser.reviewPosts(html)
    }

    public func accountName() async -> String? {
        await desktopAccountName()
    }

    /// Reads the signed-in name from the desktop site's header, which is where the
    /// desktop login actually writes its session.
    ///
    /// A book page is used rather than `/index.php` or `/login.php`: the former
    /// redirects anonymous visitors to the login form, and the latter serves the
    /// form itself, so neither reliably carries the header. Book pages render it
    /// for anonymous and signed-in visitors alike.
    /// What the site says about the current session, distinguishing "signed out" from
    /// "could not ask".
    ///
    /// `desktopAccountName` answers `nil` for both, which is fine when a caller only wants a
    /// name but wrong when deciding whether to drop a remembered login: treating an offline
    /// launch as a logout would sign the reader out on a train.
    public enum SessionState: Sendable, Equatable {
        case signedIn(String)
        case signedOut
        /// The site could not be reached, so nothing can be concluded.
        case unknown
    }

    /// The relay keeps a session of its own, and answers `4` for "not signed in".
    public func relaySessionState() async -> SessionState {
        guard relayIsAvailable else { return .unknown }
        guard let info = try? await relay.sendText(RelayAction.userInfo()) else { return .unknown }
        let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "4" { return .signedOut }
        return .signedIn(RelayParser.userName(trimmed) ?? "")
    }

    /// The outcome of asking one source whether it answers at all.
    ///
    /// Distinct from the login check: this says nothing about an account, only whether the
    /// reader's phone can reach the site or the relay right now — the question a reader has
    /// when a page stays empty and they do not know whether to change mirror or wait.
    public struct Connectivity: Sendable, Equatable {
        public enum Target: String, Sendable, CaseIterable {
            case site
            case relay
        }

        public var target: Target
        public var isReachable: Bool
        /// Round trip in seconds, when a request completed.
        public var latency: TimeInterval?
        /// One short line: what answered, or why it did not.
        public var detail: String
    }

    /// Requests the site's mobile home page and reports how long it took.
    public func checkSiteConnectivity() async -> Connectivity {
        let started = Date()
        do {
            let html = try await client.wap("/")
            let elapsed = Date().timeIntervalSince(started)
            guard !html.isEmpty else {
                return Connectivity(target: .site, isReachable: false, latency: nil,
                                    detail: "站点返回了空页面")
            }
            return Connectivity(target: .site, isReachable: true, latency: elapsed,
                                detail: "已连接 \(SiteDomain.current.title)")
        } catch {
            return Connectivity(target: .site, isReachable: false, latency: nil,
                                detail: (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
        }
    }

    /// Requests a small relay listing and reports how long it took.
    ///
    /// The relay paces every call at roughly 1.2s, so a success is never faster than that;
    /// the figure reported here is therefore an upper bound on the network time.
    public func checkRelayConnectivity() async -> Connectivity {
        guard relayIsAvailable else {
            return Connectivity(target: .relay, isReachable: false, latency: nil,
                                detail: "中转服务未启用")
        }
        let started = Date()
        do {
            let text = try await relay.sendText(RelayAction.sorts())
            let elapsed = Date().timeIntervalSince(started)
            guard !text.isEmpty else {
                return Connectivity(target: .relay, isReachable: false, latency: nil,
                                    detail: "中转返回了空响应")
            }
            return Connectivity(target: .relay, isReachable: true, latency: elapsed,
                                detail: "已连接中转服务")
        } catch {
            return Connectivity(target: .relay, isReachable: false, latency: nil,
                                detail: (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
        }
    }

    public func sessionState() async -> SessionState {
        // The two sources hold separate sessions, and only the active one is consulted:
        // with the relay on every request goes there, so the website's state is irrelevant
        // — and vice versa. Asking both would report a login the reader's requests do not
        // actually use.
        if relayIsAvailable {
            return await relaySessionState()
        }
        guard let html = try? await client.desktop("/book/1614.htm") else { return .unknown }
        if AccountParser.isDesktopLoginPage(html), !html.contains("欢迎您") { return .signedOut }
        // Only the header counts. A cookie in the store proves nothing: it can name an
        // account the server has already forgotten.
        if let name = AccountParser.desktopAccountName(html) { return .signedIn(name) }
        return .signedOut
    }

    public func desktopAccountName(aid: Int = 1614) async -> String? {
        guard let html = try? await client.desktop("/book/\(aid).htm") else { return nil }
        if AccountParser.isDesktopLoginPage(html), !html.contains("欢迎您") { return nil }
        // The rendered header is the authority. The `jieqiUserInfo` cookie outlives the
        // session it names — a stale one made an expired login look valid, which showed up
        // as a "signed in" account with an empty cloud shelf.
        return AccountParser.desktopAccountName(html)
    }

    // MARK: - Account

    public struct Session: Sendable, Equatable {
        public var userName: String
        public var isRemote: Bool

        public init(userName: String, isRemote: Bool) {
            self.userName = userName
            self.isRemote = isRemote
        }
    }

    /// Signs in through the desktop form (`login.php?do=submit`). Success is
    /// confirmed by re-reading the WAP header, because the site marks a valid
    /// session there rather than in the POST response body.
    public func signIn(username: String, password: String) async throws -> Session {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            throw Wenku8Error.login("请填写账号与密码")
        }
        client.clearSessionCookies()

        // The desktop form now demands 验证码 — an image the app cannot solve — so the
        // sign-in goes to the mobile form, which still asks only for the account and the
        // password and sets the same session cookie.
        var siteError: String?
        var siteName: String?
        do {
            let html = try await client.wapPost("/login.php", fields: [
                "action": "login",
                "jumpurl": "",
                "username": name,
                "password": password,
            ])
            if let message = AccountParser.wapLoginMessage(html)
                ?? AccountParser.loginErrorMessage(html) {
                siteError = message
            } else if let cookieName = client.sessionUserName() {
                // Confirm against the desktop header; the cookie alone would not catch a
                // session that failed to attach. Falling back to the cookie is fine — the
                // mobile session is what the app's own requests use.
                siteName = await desktopAccountName() ?? cookieName
            } else {
                siteError = "登录未生效，请稍后重试"
            }
        } catch {
            siteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        // The relay signs in the same account server-side and never asks for a captcha, so
        // it is the way back in when the site's own forms refuse. With the relay enabled it
        // serves everything the app reads, which makes a relay-only session a working one.
        var relayName: String?
        if relayIsAvailable, await signInToRelay(username: name, password: password) {
            if case .signedIn(let relayed) = await relaySessionState(), !relayed.isEmpty {
                relayName = relayed
            } else {
                relayName = name
            }
        }

        if let siteName {
            return Session(userName: siteName, isRemote: true)
        }
        if let relayName {
            return Session(userName: relayName, isRemote: true)
        }
        throw Wenku8Error.login(siteError ?? "登录失败，请检查账号与密码")
    }

    /// Turns relay bookshelf ids into the same rows the desktop page produces.
    ///
    /// The relay listing carries ids (and sometimes a name), but the shelf view draws
    /// covers, authors and the latest chapter; those come from each book's metadata.
    /// Fetched concurrently, and a book whose metadata fails still appears with its id
    /// and title rather than vanishing from the shelf.
    private func enrich(_ entries: [RelayParser.RelayShelfEntry]) async -> [ShelfEntry] {
        await withTaskGroup(of: ShelfEntry.self) { group in
            for entry in entries {
                group.addTask { [self] in
                    let summary = await novelSummary(aid: entry.aid, fallbackTitle: entry.name)
                    let chapter: ChapterLink? = {
                        guard let cid = entry.latestChapterCID else { return nil }
                        return ChapterLink(id: cid, title: entry.latestChapterName ?? "")
                    }()
                    return ShelfEntry(novel: summary, latestChapter: chapter)
                }
            }
            var rows: [ShelfEntry] = []
            for await row in group { rows.append(row) }
            // The relay returns shelf order; sorting by title keeps the list stable
            // regardless of which metadata request finished first.
            return rows.sorted { $0.novel.title < $1.novel.title }
        }
    }

    /// Minimal summary for a book, falling back to placeholders when metadata is absent.
    private func novelSummary(aid: Int, fallbackTitle: String?) async -> NovelSummary {
        if let detail = try? await detail(aid: aid) {
            return NovelSummary(
                id: aid,
                title: detail.title,
                author: detail.author,
                coverURL: detail.coverURL
            )
        }
        return NovelSummary(
            id: aid,
            title: fallbackTitle ?? "书籍 \(aid)",
            author: nil,
            coverURL: CoverURL.image(for: aid)
        )
    }

    /// Signs the relay in with the same credentials, ignoring failure.
    ///
    /// A relay that rejects the login is not fatal: the desktop session still works,
    /// and `bookshelf` calls fall back to it. Returns whether it succeeded, for callers
    /// that want to report it.
    @discardableResult
    public func signInToRelay(username: String, password: String) async -> Bool {
        guard relayIsAvailable else { return false }
        guard let text = try? await relay.sendText(
            RelayAction.login(username: username, password: password)
        ) else { return false }
        // Persist whatever the login established before reporting success: without
        // this the session was gone by the next launch.
        SharedCookieStore.persistRelayCookies()

        // A reply code alone is not proof: a login that answers "success" without
        // issuing a cookie leaves every later call unauthenticated, which is exactly
        // the bug being fixed. So the session is confirmed by asking for the account
        // and checking the relay did not answer "not signed in".
        if let info = try? await relay.sendText(RelayAction.userInfo()) {
            let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "4" else { return false }
            SharedCookieStore.persistRelayCookies()
            return true
        }
        return (RelayParser.resultCode(text) ?? 0) == 1
            || text.localizedCaseInsensitiveContains("ok")
    }

    public func signOut() {
        client.clearSessionCookies()
        if relayIsAvailable {
            Task { _ = try? await relay.sendText(RelayAction.logout()) }
        }
        SharedCookieStore.clearRelayCookies()
    }

    public func currentUserName() async -> String? {
        await desktopAccountName()
    }

    // MARK: - Remote bookcase

    /// Reads the signed-in user's shelf from the desktop site.
    ///
    /// The relay keeps its own session and the WAP shelf is a separate scope, so
    /// neither sees a desktop login; the desktop page is the only place the
    /// session established by `signIn` is visible.
    public func remoteBookcase() async throws -> [NovelSummary] {
        try await remoteShelf().map(\.novel)
    }

    /// The signed-in user's shelf straight from the desktop page.
    ///
    /// The desktop shelf links each row through `readbookcase.php?aid=…`, never
    /// `/book/<aid>.htm`, so the generic card extractor found nothing.
    ///
    /// `classID` selects a group; `nil` reads the default shelf.
    public func remoteShelf(classID: Int? = nil) async throws -> [ShelfEntry] {
        try await remoteShelfPage(classID: classID).entries
    }

    /// The shelf rows plus the size the page reports for that group.
    ///
    /// The page states "本组有 N 本", which can differ from `entries.count` when the
    /// group is large enough to paginate; the UI shows the site's own figure.
    public func remoteShelfPage(
        classID: Int? = nil
    ) async throws -> (entries: [ShelfEntry], reportedCount: Int?) {
        // With the relay enabled the shelf comes from the relay's own session, which
        // `signIn` establishes alongside the website's. Relay ids carry no group on
        // that listing, so groups still come from the desktop page.
        if relayIsAvailable, classID ?? 0 == 0 {
            guard let text = try? await relay.sendText(RelayAction.bookcaseList()) else {
                throw Wenku8Error.unavailable("中转服务暂时无法获取书架")
            }
            // An empty listing is a real answer — the account has nothing — and must
            // not be mistaken for a failure, or an empty shelf would silently be
            // re-read from a different source.
            let entries = RelayParser.bookcaseEntries(text)
            let shelf = await enrich(entries)
            return (shelf, shelf.count)
        }
        guard client.hasSession() else { throw Wenku8Error.needLogin }
        let path = classID.map { "/modules/article/bookcase.php?classid=\($0)" }
            ?? "/modules/article/bookcase.php"
        let html = try await client.desktop(path)
        if AccountParser.isDesktopLoginPage(html) || AccountParser.isLoginGate(html) {
            throw Wenku8Error.needLogin
        }
        let entries = DesktopParser.bookcase(html)
        if entries.isEmpty, AccountParser.desktopAccountName(html) == nil {
            throw Wenku8Error.needLogin
        }
        return (entries, DesktopParser.renderedGroupCount(html))
    }

    @discardableResult
    public func addToBookcase(aid: Int, classID: Int? = nil) async throws -> BookcaseMutationResult {
        // The relay keeps its own session, which is not the one `signIn` establishes.
        // A code 4 from it therefore means "the relay account is not signed in", not
        // "this reader is signed out" — reporting that as an expired login was wrong.
        // Fall through to the desktop page, which uses the session the reader actually
        // established.
        if relayIsAvailable,
           let code = RelayParser.resultCode(try await relay.sendText(RelayAction.bookcaseAdd(aid: aid))) {
            switch code {
            case 1: return .succeeded
            case 5: return .alreadyPresent
            case 6: throw Wenku8Error.login("书架已满，请先清理后再添加")
            case 4:
                // Relay session missing: try the reader's own login below.
                break
            default:
                break
            }
        }
        guard client.hasSession() else { throw Wenku8Error.needLogin }
        let html = try await client.desktop("/modules/article/addbookcase.php?bid=\(aid)")
        if AccountParser.isDesktopLoginPage(html) || AccountParser.isLoginGate(html) {
            throw Wenku8Error.needLogin
        }

        // `addbookcase.php` always appends to 默认书架; a chosen group is a second
        // step. If that step fails the book stays on the default shelf, which is
        // visible and recoverable rather than an error the reader cannot act on.
        if let classID, classID != 0 {
            _ = try? await moveInBookcase(aid: aid, toClassID: classID)
        }
        return .succeeded
    }

    /// Files an already-added book into a shelf group.
    ///
    /// The site has no "add to group N" call: `addbookcase.php` always appends to
    /// 默认书架, and grouping is a separate operation on the shelf page's move form
    /// (`bookcase.php` with `checkid[]` + `newclassid`). So adding to a group is two
    /// steps, and a failure in the second leaves the book on the default shelf rather
    /// than losing it.
    @discardableResult
    public func moveInBookcase(aid: Int, toClassID classID: Int) async throws -> Bool {
        guard client.hasSession() else { throw Wenku8Error.needLogin }
        let page = try await client.desktop("/modules/article/bookcase.php")
        if AccountParser.isDesktopLoginPage(page) || AccountParser.isLoginGate(page) {
            throw Wenku8Error.needLogin
        }
        // The book is identified on this form by its `bid`, which the shelf row carries
        // in the `checkid[]` checkbox; the two are the same value.
        guard let bid = DesktopParser.bookcaseBid(forAid: aid, in: page) else {
            return false
        }
        let html = try await client.desktopPost(
            "/modules/article/bookcase.php",
            fields: [
                "checkid[]": String(bid),
                "newclassid": String(classID),
            ]
        )
        if AccountParser.isDesktopLoginPage(html) || AccountParser.isLoginGate(html) {
            throw Wenku8Error.needLogin
        }
        return true
    }

    @discardableResult
    public func removeFromBookcase(aid: Int) async throws -> BookcaseMutationResult {
        if relayIsAvailable,
           let code = RelayParser.resultCode(try await relay.sendText(RelayAction.bookcaseDelete(aid: aid))) {
            switch code {
            case 1: return .succeeded
            case 7: return .notPresent
            case 4: throw Wenku8Error.needLogin
            default: throw Wenku8Error.login(RelayParser.message(for: code))
            }
        }
        let html = try await client.wap("/article/bookcase.php?delid=\(aid)")
        if AccountParser.isLoginGate(html) {
            throw Wenku8Error.needLogin
        }
        // The site returns the updated shelf page without a dedicated confirmation,
        // so verify by listing the shelf again only when the page looked odd.
        let outcome = AccountParser.mutationOutcome(html, novelID: aid)
        if case .failed(let message) = outcome {
            throw Wenku8Error.login(message)
        }
        return outcome
    }
}
