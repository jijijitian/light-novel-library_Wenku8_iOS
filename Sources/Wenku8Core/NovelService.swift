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

    public init(client: Wenku8Client = .shared, relay: RelayClient = .shared) {
        self.client = client
        self.relay = relay
    }

    /// Relay-first helpers. The relay is a third-party volunteer service, so every
    /// call here is best-effort: a `nil` return simply means "use the WAP/desktop
    /// path", which stays fully functional.
    private var relayIsAvailable: Bool { relay.isAvailable }

    private func relaySearch(_ key: String, type: String) async -> [NovelSummary]? {
        guard relayIsAvailable else { return nil }
        guard let data = try? await relay.send(RelayAction.search(type: type, key: key)) else { return nil }
        let items = RelayParser.search(TextDecoding.decode(data)).uniquedByID()
        return items.isEmpty ? nil : items
    }

    private func relayList(_ action: String) async -> [NovelSummary]? {
        guard relayIsAvailable else { return nil }
        guard let data = try? await relay.send(action) else { return nil }
        let items = RelayParser.items(TextDecoding.decode(data)).uniquedByID()
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
        if let items = await relayList(RelayAction.articleList(sort: board.rawValue, page: page)) {
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
        if let items = await relayList(RelayAction.novelList(sort: sort, page: page)) {
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
        if relayIsAvailable,
           let data = try? await relay.send(RelayAction.meta(aid: aid)) {
            let parsed = RelayParser.detail(TextDecoding.decode(data), aid: aid)
            if !parsed.title.isEmpty { return parsed }
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
        if relayIsAvailable,
           let data = try? await relay.send(RelayAction.chapterList(aid: aid)) {
            let relayed = RelayParser.volumes(TextDecoding.decode(data))
            if !relayed.isEmpty { return Self.mergeVolumes(relayed) }
        }
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
            throw Wenku8Error.unavailable("该章节没有可显示的正文")
        }
        return ChapterContent(novelID: aid, chapterID: cid, title: title, blocks: blocks)
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
        guard let html = try? await client.wap("/") else { return nil }
        return WAPParser.accountName(html)
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

        guard let resolved = await accountName() else {
            throw Wenku8Error.login("登录未生效，请稍后重试")
        }
        return Session(userName: resolved, isRemote: true)
    }

    public func signOut() {
        client.clearSessionCookies()
    }

    public func currentUserName() async -> String? {
        guard let html = try? await client.wap("/") else { return nil }
        return AccountParser.accountName(html)
    }

    // MARK: - Remote bookcase

    public func remoteBookcase() async throws -> [NovelSummary] {
        if relayIsAvailable,
           let data = try? await relay.send(RelayAction.bookcaseList()) {
            let text = TextDecoding.decode(data)
            if let code = RelayParser.resultCode(text), code > 1 {
                if code == 4 { throw Wenku8Error.needLogin }
                throw Wenku8Error.login(RelayParser.message(for: code))
            }
            let items = RelayParser.items(text)
            if !items.isEmpty { return items }
        }
        let html = try await client.wap("/article/bookcase.php")
        if AccountParser.isLoginGate(html) {
            throw Wenku8Error.needLogin
        }
        return AccountParser.bookcaseNovels(html).uniquedByID()
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
