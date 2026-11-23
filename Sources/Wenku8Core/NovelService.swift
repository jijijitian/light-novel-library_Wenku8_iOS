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

/// Keeps concurrent metadata fetches for the same book from running twice.
///
/// More than one caller asks for a book's catalogue at launch — the shelf's own refresh and
/// its metadata pass both walk the shelf — and on the website path a catalogue costs one
/// request per page. Without this, every launch downloaded each missing book's catalogue
/// twice over.
actor MetadataFetchRegistry {
    static let shared = MetadataFetchRegistry()

    private var inFlight: Set<Int> = []

    /// Returns true when the caller is the one that should do the work.
    func begin(_ aid: Int) -> Bool {
        inFlight.insert(aid).inserted
    }

    func end(_ aid: Int) {
        inFlight.remove(aid)
    }
}

public struct NovelService: Sendable {
    private let client: Wenku8Client
    /// Local download cache consulted before the network.
    private let offline: OfflineStore

    public init(
        client: Wenku8Client = .shared,
        offline: OfflineStore = .shared
    ) {
        self.client = client
        self.offline = offline
    }

    /// A ranking board, one page at a time.
    ///
    /// Boards run to hundreds of pages (the day-visit board reports 426), so a screen
    /// that fetched only page 1 showed a fraction of the list with no way to reach the
    /// rest.
    public func rankPage(_ board: RankBoard, page: Int) async throws -> NovelListPage {
        let novels = try await websiteRank(board, page: page)
        return NovelListPage(novels: novels, totalPages: nil)
    }

    /// A library category, one page at a time.
    public func libraryPage(_ category: Int, page: Int) async throws -> NovelListPage {
        let sort = category == 0 ? "all" : "\(category)"
        let novels = try await websiteLibrary(category, page: page)
        return NovelListPage(novels: novels, totalPages: nil)
    }

    /// A search result, one page at a time.
    /// A search result as a page.
    ///
    /// Search returns everything the site has in one response, so the total is 1 and never
    /// nil: a nil total reads as "there may be more", which left the list asking for a page
    /// two that does not exist and showing 正在载入 forever.
    public func searchPage(_ query: SearchQuery, page: Int) async throws -> NovelListPage {
        let keyword = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return NovelListPage(novels: [], totalPages: 1) }
        if page > 1 { return NovelListPage(novels: [], totalPages: 1) }
        let novels = try await search(query)
        return NovelListPage(novels: novels, totalPages: 1)
    }

    // MARK: - Home

    /// The home screen's rows, read from the WAP home page.
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

    /// The home rows, fetched one after another from the top of the page downwards.
    ///
    /// Each result is handed to `onRow` as soon as it arrives, so the page fills in
    /// top-to-bottom instead of appearing all at once when the slowest section finishes.
    /// The order matters for two reasons: the banner is built from the first section, and
    /// the reader sees the top of the page first — so a section that is slow or fails
    /// must not hold up the ones above it.
    ///
    public func homeRowsStreaming(
        onRow: @escaping @Sendable (HomeRow) async -> Void
    ) async -> [HomeRow] {
        // One page is parsed, so this is all-or-nothing by nature. It must call
        // `legacyHomeRows`, not `homeRows`: the latter wraps this same function, so
        // calling it here recursed until the heap was exhausted.
        let rows = (try? await legacyHomeRows()) ?? []
        for row in rows { await onRow(row) }
        return rows
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
        try await websiteRank(board, page: page)
    }

    /// A board read from the website.
    private func websiteRank(_ board: RankBoard, page: Int) async throws -> [NovelSummary] {
        let path = "/article/toplist.php?sort=\(board.rawValue)&page=\(page)"
        let html = try await client.wap(path)
        if WAPParser.requiresLogin(html) {
            return try await rankedFallback(board, page: page, needsLogin: true)
        }
        let items = WAPParser.linksIn(html).uniquedByID()
        if items.isEmpty {
            return try await rankedFallback(board, page: page, needsLogin: false)
        }
        return items
    }

    /// The desktop ranking, or a message saying why there is none.
    ///
    /// The yearly ranking used to be substituted here, which made an unreadable board look
    /// like a board — the wrong books under the wrong title. A board that cannot be read
    /// now says so.
    private func rankedFallback(
        _ board: RankBoard,
        page: Int,
        needsLogin: Bool
    ) async throws -> [NovelSummary] {
        if let items = try? await desktopRank(board, page: page), !items.isEmpty {
            return items
        }
        if needsLogin {
            throw Wenku8Error.unavailable("排行榜需要登录文库账号后才能查看，请先登录。")
        }
        throw Wenku8Error.unavailable("排行榜暂时无法访问，请稍后再试")
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

    // MARK: - Tags

    /// A tag's book list, read from the site's tag page.
    public func novels(tag: String, page: Int = 1, sort: TagSort = .updated) async throws -> NovelListPage {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Wenku8Error.unavailable("标签为空") }
        guard let encoded = TextDecoding.formEncodeGBK(name) else {
            throw Wenku8Error.unavailable("这个标签无法打开，请稍后再试")
        }
        let html = try await client.desktop(
            "/modules/article/tags.php?t=\(encoded)&page=\(page)&v=\(sort.value)"
        )
        if AccountParser.isDesktopLoginPage(html) {
            throw Wenku8Error.needLogin
        }
        let parsed = DesktopParser.tagPage(html)
        return NovelListPage(novels: parsed.novels, totalPages: parsed.totalPages)
    }

    /// The website homepage's book blocks.
    ///
    /// The homepage needs a session: anonymous visitors are redirected to the login form.
    public func exploreBlocks() async throws -> [DesktopParser.HomeBlock] {
        let html = try await client.desktop("/index.php")
        if AccountParser.isDesktopLoginPage(html) {
            throw Wenku8Error.needLogin
        }
        let blocks = DesktopParser.homeBlocks(html)
        guard !blocks.isEmpty else {
            throw Wenku8Error.unavailable("首页暂时无法读取，请稍后再试。")
        }
        return blocks
    }

    /// The site's tag cloud page: its groups of tags and its explanation of the service.
    ///
    /// Both live on the same page, so they come back together and are cached together.
    public struct TagCloudPage: Sendable {
        public var groups: [DesktopParser.TagGroup]
        public var guide: DesktopParser.TagGuide?
    }

    public func tagCloudPage() async throws -> TagCloudPage {
        let html = try await client.desktop("/modules/article/tags.php")
        if AccountParser.isDesktopLoginPage(html) {
            throw Wenku8Error.needLogin
        }
        let groups = DesktopParser.tagCloudGroups(html)
        guard !groups.isEmpty else {
            throw Wenku8Error.unavailable("标签页暂时无法读取，请稍后再试。")
        }
        return TagCloudPage(groups: groups, guide: DesktopParser.tagGuide(html))
    }

    /// The heat ranking page (`/top.php`): twenty columns, one per library and measure.
    ///
    /// The page needs a session.
    public func heatBoards() async throws -> [DesktopParser.HeatBoard] {
        let html = try await client.desktop("/top.php")
        if AccountParser.isDesktopLoginPage(html) {
            throw Wenku8Error.needLogin
        }
        let boards = DesktopParser.heatBoards(html)
        guard !boards.isEmpty else {
            throw Wenku8Error.unavailable("热度排名暂时无法读取，请稍后再试。")
        }
        return boards
    }

    /// Every tag the site publishes, from its tag cloud.
    public func tagCloud() async throws -> [String] {
        let html = try await client.desktop("/modules/article/tags.php")
        if AccountParser.isDesktopLoginPage(html) {
            throw Wenku8Error.needLogin
        }
        return DesktopParser.tagCloud(html)
    }

    public func library(_ category: Int, page: Int = 1) async throws -> [NovelSummary] {
        let sort = category == 0 ? "all" : "\(category)"
        return try await websiteLibrary(category, page: page)
    }

    /// A category read from the website.
    private func websiteLibrary(_ category: Int, page: Int) async throws -> [NovelSummary] {
        let path = "/article/sortlist.php?class=\(category)&page=\(page)"
        let html = try await client.wap(path)
        if WAPParser.requiresLogin(html) {
            // The library listing is session-only on every mirror, so report the real
            // reason instead of substituting an unrelated ranking.
            throw Wenku8Error.needLogin
        }
        return WAPParser.linksIn(html).uniquedByID()
    }

    /// Library categories, read from the site's sort page.
    public func categories() async throws -> [LibraryCategory] {
        let html = try await client.wap("/article/sort.php")
        let list = WAPParser.libraryCategories(html)
        return list.isEmpty ? LibraryCategory.all : list
    }

    // MARK: - Search

    public func search(_ query: SearchQuery) async throws -> [NovelSummary] {
        let keyword = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let fields = [
            "action": "search",
            "searchtype": query.field.parameter,
            "searchkey": keyword,
        ]
        var lastError: Error?
        // The chosen mirror first, then the others. That order matters more for a POST than
        // anywhere else: an alias that answers 301 turns this into a GET and drops the search
        // fields, so a mirror that redirects must not be preferred. Whether `.cc` redirects
        // depends on the network the reader is on — it serves pages itself on some and
        // redirects to `.net` on others — so the choice is left to the fallback order rather
        // than resolved in advance.
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
    /// Each piece is skipped when it is already stored, so re-fetching a record that is
    /// already on disk does not cost another request.
    public func cacheDetailFully(aid: Int) async {
        guard await MetadataFetchRegistry.shared.begin(aid) else { return }
        await performCacheDetail(aid: aid)
        await MetadataFetchRegistry.shared.end(aid)
    }

    private func performCacheDetail(aid: Int) async {
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
        return try await websiteDetail(aid: aid)
    }
    /// A book's detail read from the website.
    private func websiteDetail(aid: Int) async throws -> NovelDetail {
        let html = try await client.wap("/article/articleinfo.php?id=\(aid)")
        var detail = WAPParser.novelDetail(html, aid: aid)
        if detail.title.isEmpty {
            let desktop = try await client.desktop("/book/\(aid).htm")
            detail = DesktopParser.novelDetail(desktop, aid: aid)
        }
        // A delisted book's own pages are empty, so its notice is read from the desktop page
        // that still renders it — the same page the tags come from.
        if let book = try? await client.desktop("/book/\(aid).htm") {
            detail.isRestricted = DesktopParser.isDelisted(book)
        }
        // The mobile page carries no tags; the desktop book page does. They are read once
        // and then kept with the book, so only the first open pays for the extra request.
        if detail.tags == nil {
            detail.tags = await offline.entry(for: aid)?.detail?.tags
            if detail.tags == nil, let book = try? await client.desktop("/book/\(aid).htm") {
                detail.tags = DesktopParser.tags(book)
            }
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
            // A delisted book has no readable catalogue through the usual endpoints, but its
            // index page still lists every volume and chapter.
            if let rebuilt = try? await restrictedCatalogue(aid: aid), !rebuilt.isEmpty {
                await offline.cacheVolumes(rebuilt, for: aid)
                return rebuilt
            }
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

    // MARK: - Restricted books (download-only)

    /// The per-volume text download the site still serves for a delisted book.
    ///
    /// A book taken down "at rights holders' request" has no readable pages, but its text is
    /// still published one volume at a time:
    ///
    ///     https://dl.wenku8.com/packtxt.php?aid=<aid>&vid=<vid>&type=gbk
    ///
    /// `type=gbk` is the encoding actually written, despite the response saying `utf-8`; the
    /// bytes are decoded with the app's GBK table.
    public static func textPackURL(aid: Int, vid: Int) -> URL? {
        URL(string: "https://dl.wenku8.com/packtxt.php?aid=\(aid)&vid=\(vid)&type=gbk")
    }

    /// Downloads one volume's pack and splits it into chapters.
    public func downloadedVolume(
        aid: Int,
        vid: Int,
        volumeName: String? = nil
    ) async throws -> TextPackParser.ParsedVolume? {
        guard let url = Self.textPackURL(aid: aid, vid: vid) else { return nil }
        let response = try await client.get(url, referer: SiteDomain.current.webURL("/book/\(aid).htm").absoluteString)
        guard !response.data.isEmpty else { return nil }
        return TextPackParser.parse(TextDecoding.decode(response.data), volumeName: volumeName)
    }

    /// One chapter of a delisted book, from its volume download.
    ///
    /// The catalogue built from the index page keeps the chapter ids the site assigned, and a
    /// volume's id is one less than its first chapter's, so the chapter can be found again
    /// by asking for that volume's pack and matching the position within it.
    private func restrictedChapter(aid: Int, cid: Int) async throws -> ChapterContent? {
        let cached = await offline.cachedVolumes(for: aid)
        let volumes: [Volume]
        if let cached, !cached.isEmpty {
            volumes = cached
        } else if let rebuilt = try? await restrictedCatalogue(aid: aid) {
            volumes = rebuilt
        } else {
            return nil
        }
        guard !volumes.isEmpty else { return nil }
        for volume in volumes {
            guard let position = volume.chapters.firstIndex(where: { $0.id == cid }),
                  let vid = Int(volume.id) else { continue }
            guard let parsed = try await downloadedVolume(aid: aid, vid: vid, volumeName: volume.title),
                  position < parsed.chapters.count else { continue }
            let chapter = parsed.chapters[position]
            let blocks = chapter.paragraphs.map { ChapterContent.Block.paragraph($0) }
            return ChapterContent(
                novelID: aid,
                chapterID: cid,
                title: chapter.title,
                blocks: blocks
            )
        }
        return nil
    }

    /// A delisted book's catalogue, rebuilt from its index page.
    ///
    /// The endpoint that normally serves a catalogue returns an empty page for these books,
    /// while `/novel/<group>/<aid>/index.htm` keeps the whole table of contents. The volume id
    /// a download needs never appears on it, so it is derived from the volume's first chapter
    /// id instead.
    public func restrictedCatalogue(aid: Int) async throws -> [Volume] {
        let group = max(0, aid / 1000)
        let html = try await client.desktop("/novel/\(group)/\(aid)/index.htm")
        guard let parsed = DesktopParser.restrictedCatalogue(html) else { return [] }
        return parsed.volumes.map { entry in
            Volume(id: String(entry.vid), title: entry.title, chapters: entry.chapters)
        }
    }

    private func onlineVolumes(aid: Int) async throws -> [Volume] {
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
    /// The group is `max(0, aid / 1000)`, matching the site's own folder layout: books with
    /// an id below 1000 live in `/novel/0/`, which a `max(1, …)` turned into a 404.
    /// Some books are only reachable this way, so an empty WAP catalogue must not
    /// be reported as "this book has no chapters".
    private func desktopVolumes(aid: Int) async throws -> [Volume] {
        let group = max(0, aid / 1000)
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
        // A delisted book's chapters cannot be fetched by id at all; its text comes from the
        // per-volume download and is stored on the way through, so this is paid once.
        if let restricted = try? await restrictedChapter(aid: aid, cid: cid) {
            await offline.saveChapter(restricted, for: aid)
            return restricted
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
        let group = max(0, aid / 1000)
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

    /// One page of a book's reviews.
    ///
    /// The list is paged — a popular book runs to hundreds of pages — so the page count
    /// comes back with the rows and the caller decides when to ask for the next one.
    public func reviews(aid: Int, page: Int = 1, force: Bool = false) async throws -> ReviewPage {
        // Cached first, like the blurb and the catalogue: the stored page appears at once
        // and only a deliberate refresh goes to the site.
        if !force, let cached = await offline.cachedReviews(for: aid) {
            let total = await offline.cachedReviewPages(for: aid) ?? 1
            let stored = await offline.cachedReviewPage(for: aid)
            // Page one is always worth showing; a deeper page is only useful when it is the
            // one being asked for.
            if page == 1 || page == stored {
                return ReviewPage(
                    reviews: cached,
                    page: stored,
                    totalPages: total,
                    isCached: true
                )
            }
        }
        do {
            let html = try await client.wap("/article/reviews.php?aid=\(aid)&type=all&page=\(page)")
            if WAPParser.requiresLogin(html) {
                throw Wenku8Error.needLogin
            }
            let reviews = WAPParser.reviews(html)
            let pagination = WAPParser.reviewPagination(html)
            // The first page joins the book's metadata, so a book opened offline still
            // says what readers made of it.
            // Every page that is fetched joins the stored list, so what was read stays
            // readable: a page-one-only cache meant scrolling loaded pages that were thrown
            // away the next time the list opened.
            await storeReviews(reviews, aid: aid, page: page, totalPages: pagination?.total ?? page)
            return ReviewPage(
                reviews: reviews,
                page: page,
                totalPages: pagination?.total ?? page
            )
        } catch {
            // Offline, or the site refused: the stored first page is better than an empty
            // screen, and the reader can still see what was said.
            if page == 1, let cached = await offline.cachedReviews(for: aid) {
                return ReviewPage(reviews: cached, page: 1, totalPages: 1)
            }
            throw error
        }
    }

    /// Stores one page of reviews, appending to what is already held.
    private func storeReviews(
        _ reviews: [NovelReview],
        aid: Int,
        page: Int,
        totalPages: Int
    ) async {
        guard !reviews.isEmpty else { return }
        let stored = page == 1 ? [] : (await offline.cachedReviews(for: aid) ?? [])
        let known = Set(stored.map(\.id))
        let merged = stored + reviews.filter { !known.contains($0.id) }
        await offline.cacheReviews(merged, for: aid, page: page, totalPages: totalPages)
    }
    /// One page of a review thread.
    ///
    /// Threads page too — a popular one runs to a hundred pages — so the caller gets the
    /// floor list together with the page count.
    public func reviewPosts(rid: Int, page: Int = 1) async throws -> ReviewThread {
        let html = try await client.wap("/article/reviewshow.php?rid=\(rid)&page=\(page)")
        let parsed = WAPParser.reviewPosts(html)
        let pagination = WAPParser.reviewPagination(html)
        return ReviewThread(
            topic: parsed.topic,
            posts: parsed.posts,
            page: page,
            totalPages: pagination?.total ?? page
        )
    }

    public func accountName() async -> String? {
        await desktopAccountName()
    }

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
    /// The outcome of asking whether the site answers at all.
    ///
    /// Distinct from the login check: this says nothing about an account, only whether the
    /// reader's phone can reach the site right now — the question a reader has when a page
    /// stays empty and they do not know whether to change mirror or wait.
    /// A page of a review thread.
    public struct ReviewThread: Sendable {
        public var topic: String
        public var posts: [ReviewPost]
        public var page: Int
        public var totalPages: Int

        public init(topic: String, posts: [ReviewPost], page: Int, totalPages: Int) {
            self.topic = topic
            self.posts = posts
            self.page = page
            self.totalPages = totalPages
        }
    }

    /// A page of a book's review list.
    public struct ReviewPage: Sendable {
        public var reviews: [NovelReview]
        public var page: Int
        public var totalPages: Int
        /// True when the page came from the store rather than the site, so the caller knows
        /// to show it at once and refresh behind it.
        public var isCached: Bool

        public init(
            reviews: [NovelReview],
            page: Int,
            totalPages: Int,
            isCached: Bool = false
        ) {
            self.reviews = reviews
            self.page = page
            self.totalPages = totalPages
            self.isCached = isCached
        }
    }

    public struct Connectivity: Sendable, Equatable {
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
                return Connectivity( isReachable: false, latency: nil,
                                    detail: "站点返回了空页面")
            }
            return Connectivity( isReachable: true, latency: elapsed,
                                detail: "已连接 \(SiteDomain.current.title)")
        } catch {
            return Connectivity( isReachable: false, latency: nil,
                                detail: (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
        }
    }
    public func sessionState() async -> SessionState {
        return await websiteSessionState()
    }

    /// What the website says about the current session.
    private func websiteSessionState() async -> SessionState {
        guard let html = try? await client.desktop("/book/1614.htm") else { return .unknown }
        if AccountParser.isDesktopLoginPage(html), !html.contains("欢迎您") { return .signedOut }
        // Only the header counts. A cookie in the store proves nothing: it can name an
        // account the server has already forgotten.
        if let name = AccountParser.desktopAccountName(html) { return .signedIn(name) }
        return .signedOut
    }

    /// Reads the signed-in name from the desktop site's header, which is where the
    /// desktop login actually writes its session.
    ///
    /// A book page is used rather than `/index.php` or `/login.php`: the former
    /// redirects anonymous visitors to the login form, and the latter serves the
    /// form itself, so neither reliably carries the header. Book pages render it
    /// for anonymous and signed-in visitors alike.
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

        // The desktop form demands an image captcha the app cannot solve, but the mobile
        // form still asks only for the account and password and sets the same cookie.
        let html: String
        do {
            html = try await client.wapPost("/login.php", fields: [
                "action": "login",
                "jumpurl": "",
                "username": name,
                "password": password,
            ])
        } catch {
            throw Wenku8Error.login(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        if let message = AccountParser.wapLoginMessage(html)
            ?? AccountParser.loginErrorMessage(html) {
            throw Wenku8Error.login(message)
        }
        return try await confirmSiteSession()
    }
    /// Confirms a website sign-in and returns the name to show for it.
    ///
    /// The only proof is the header of a page served with the session in place. A cookie
    /// proves nothing — `jieqiUserInfo` is written even when the password is rejected, so
    /// reading it reported a failed sign-in as a success.
    private func confirmSiteSession() async throws -> Session {
        guard let html = try? await client.desktop("/book/1614.htm") else {
            throw Wenku8Error.login("无法确认登录状态，请检查网络后重试")
        }
        if let name = AccountParser.desktopAccountName(html) {
            return Session(userName: name, isRemote: true)
        }
        throw Wenku8Error.login("登录未生效，请稍后重试")
    }

    /// The login captcha, for the website form that requires one.
    public func loginCaptcha() async throws -> Data {
        try await client.captchaImage()
    }

    /// Signs in to the website with the captcha the reader read off the image.
    ///
    /// The desktop form is the only one that asks for a captcha, and it is also the one that
    /// gives a real session to the desktop pages, so it is used whenever the reader supplies
    /// a code.
    public func signInToSite(
        username: String,
        password: String,
        captcha: String
    ) async throws -> Session {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = captcha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            throw Wenku8Error.login("请填写账号与密码")
        }
        guard !code.isEmpty else {
            throw Wenku8Error.login("请填写验证码")
        }

        let html = try await client.desktopLoginPost(
            username: name,
            password: password,
            captcha: code
        )
        if let message = AccountParser.loginErrorMessage(html) {
            throw Wenku8Error.login(message)
        }
        return try await confirmSiteSession()
    }

    public func signOut() {
        client.clearSessionCookies()
    }

    public func currentUserName() async -> String? {
        await desktopAccountName()
    }

    // MARK: - Remote bookcase

    /// Reads the signed-in user's shelf from the desktop site.
    ///
    /// The WAP shelf is a separate scope from the desktop one, so the desktop page is
    /// the only place the session established by `signIn` is visible.
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
