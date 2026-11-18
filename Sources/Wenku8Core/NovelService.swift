import Foundation

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

    // MARK: - Home

    public func homeRows() async throws -> [HomeRow] {
        let html = try await client.wap("/")
        let rows = WAPParser.homeSections(html)
        if rows.isEmpty {
            return try await fallbackHomeRows()
        }
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
        // The relay is the only path that serves real ranking data anonymously.
        if let items = await relayNovelList(sort: board.rawValue, page: page) {
            return items
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
        if let items = await relayNovelList(sort: sort, page: page) {
            return items
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

    public func categories() async throws -> [LibraryCategory] {
        let html = try await client.wap("/article/sort.php")
        let list = WAPParser.libraryCategories(html)
        return list.isEmpty ? LibraryCategory.all : list
    }

    // MARK: - Search

    public func search(_ query: SearchQuery) async throws -> [NovelSummary] {
        let keyword = query.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        if let items = await relaySearch(keyword, type: query.field.parameter) {
            return items
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

    public func detail(aid: Int) async throws -> NovelDetail {
        do {
            return try await onlineDetail(aid: aid)
        } catch {
            if let entry = await offline.entry(for: aid) {
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
        if relayIsAvailable,
           let data = try? await relay.send(RelayAction.meta(aid: aid)) {
            var parsed = RelayParser.detail(TextDecoding.decode(data), aid: aid)
            if !parsed.title.isEmpty {
                // `meta` carries the short preview; `intro` carries the full text.
                if let introData = try? await relay.send(RelayAction.intro(aid: aid)) {
                    let full = RelayParser.intro(TextDecoding.decode(introData))
                    if !full.isEmpty { parsed.intro = full }
                }
                return parsed
            }
        }
        let html = try await client.wap("/article/articleinfo.php?id=\(aid)")
        var detail = WAPParser.novelDetail(html, aid: aid)
        if detail.title.isEmpty {
            let desktop = try await client.desktop("/book/\(aid).htm")
            detail = DesktopParser.novelDetail(desktop, aid: aid)
        }
        return detail
    }

    public func volumes(aid: Int) async throws -> [Volume] {
        do {
            return try await onlineVolumes(aid: aid)
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
        if relayIsAvailable,
           let data = try? await relay.send(RelayAction.chapterList(aid: aid)) {
            let relayed = RelayParser.volumes(TextDecoding.decode(data))
            if !relayed.isEmpty { return Self.mergeVolumes(relayed) }
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
        if relayIsAvailable,
           let data = try? await relay.send(RelayAction.text(aid: aid, cid: cid)) {
            let parsed = RelayParser.chapter(TextDecoding.decode(data), aid: aid, cid: cid)
            if !parsed.blocks.isEmpty { return parsed }
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
    public func desktopAccountName(aid: Int = 1614) async -> String? {
        guard let html = try? await client.desktop("/book/\(aid).htm") else { return nil }
        if AccountParser.isDesktopLoginPage(html), !html.contains("欢迎您") { return nil }
        return AccountParser.desktopAccountName(html)
            ?? client.sessionUserName()
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

        let html = try await client.desktopPost("/login.php?do=submit", fields: [
            "action": "login",
            "usecookie": "315360000",
            "username": name,
            "password": password,
        ])

        if let message = AccountParser.loginErrorMessage(html) {
            throw Wenku8Error.login(message)
        }

        // The login sets `jieqiUserInfo`; if it is absent the credentials were
        // accepted by the form but no session was created.
        guard let cookieName = client.sessionUserName() else {
            throw Wenku8Error.login("登录未生效，请稍后重试")
        }
        // Confirm against the desktop header as well, since the cookie alone
        // would not catch a server-side session that failed to attach.
        let headerName = await desktopAccountName()
        return Session(userName: headerName ?? cookieName, isRemote: true)
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
    /// The relay keeps its own session and the WAP shelf is a separate scope, so
    /// neither sees a desktop login; the desktop page is the only place the
    /// session established by `signIn` is visible.
    public func remoteBookcase() async throws -> [NovelSummary] {
        try await remoteShelf().map(\.novel)
    }

    /// The shelf groups the site offers, with the current group's size.
    ///
    /// Groups are the site's own feature: `classid=0` is 默认书架, 1…5 are the extra
    /// shelves. Reading them means the app can present the same organisation instead
    /// of flattening every book into one list.
    public func remoteShelfGroups() async throws -> [DesktopParser.ShelfGroup] {
        guard client.hasSession() else { throw Wenku8Error.needLogin }
        let html = try await client.desktop("/modules/article/bookcase.php")
        if AccountParser.isDesktopLoginPage(html) || AccountParser.isLoginGate(html) {
            throw Wenku8Error.needLogin
        }
        return DesktopParser.shelfGroups(html)
    }

    /// The signed-in user's shelf straight from the desktop page.
    ///
    /// The desktop shelf links each row through `readbookcase.php?aid=…`, never
    /// `/book/<aid>.htm`, so the generic card extractor found nothing.
    ///
    /// `classID` selects a group; `nil` reads the default shelf.
    public func remoteShelf(classID: Int? = nil) async throws -> [ShelfEntry] {
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
        return entries
    }

    @discardableResult
    public func addToBookcase(aid: Int) async throws -> BookcaseMutationResult {
        if relayIsAvailable,
           let code = RelayParser.resultCode(try await relay.sendText(RelayAction.bookcaseAdd(aid: aid))) {
            switch code {
            case 1: return .succeeded
            case 5: return .alreadyPresent
            case 4: throw Wenku8Error.needLogin
            case 6: throw Wenku8Error.login("书架已满，请先清理后再添加")
            default: throw Wenku8Error.login(RelayParser.message(for: code))
            }
        }
        let html = try await client.wap("/article/addbookcase.php?bid=\(aid)")
        let outcome = AccountParser.mutationOutcome(html, novelID: aid)
        switch outcome {
        case .notSignedIn:
            throw Wenku8Error.needLogin
        case .failed(let message):
            throw Wenku8Error.login(message)
        default:
            return outcome
        }
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
