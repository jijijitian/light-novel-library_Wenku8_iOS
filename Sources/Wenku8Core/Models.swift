import Foundation

/// One of a book's tags, as the source spells it.
public struct NovelTag: Hashable, Codable, Sendable, Identifiable {
    public var name: String

    public var id: String { name }

    public init(_ name: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits the source's space-separated tag string.
    ///
    /// Both the relay and the website send tags as one string — `奇幻 冒险 百合` — and no tag
    /// contains a space, so splitting on whitespace is what they intend.
    public static func split(_ raw: String?) -> [NovelTag]? {
        guard let raw, !raw.isEmpty else { return nil }
        let names = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        return names.isEmpty ? nil : names.map(NovelTag.init)
    }
}

public struct NovelSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var title: String
    public var author: String?
    public var coverURL: URL?
    /// Optional so a stored summary written before tags existed still decodes.
    public var tags: [NovelTag]?

    public init(
        id: Int,
        title: String,
        author: String? = nil,
        coverURL: URL? = nil,
        tags: [NovelTag]? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.tags = tags
    }
}

/// One page of a listing, with the total the service reports.
///
/// The lists are paginated — 426 pages of ranking, for instance — so a screen that only
/// ever asks for page 1 shows a fraction of what exists. Carrying the total lets the UI
/// say how far it has got and stop at the end instead of requesting page 427 forever.
public struct NovelListPage: Sendable {
    public var novels: [NovelSummary]
    /// Total pages, when the source states it; `nil` means "unknown, try another page".
    public var totalPages: Int?

    public init(novels: [NovelSummary], totalPages: Int?) {
        self.novels = novels
        self.totalPages = totalPages
    }

    /// Whether a page after `page` could exist.
    public func hasMore(after page: Int) -> Bool {
        guard let totalPages else { return !novels.isEmpty }
        return page < totalPages && !novels.isEmpty
    }
}

public struct NovelDetail: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var title: String
    public var author: String
    public var category: String
    public var status: String
    public var wordCount: String
    public var updatedAt: String
    public var intro: String
    public var coverURL: URL?
    public var latestChapter: ChapterLink?
    public var recommendations: [NovelSummary]
    /// Absent when the source does not publish tags for a book — the website's book page
    /// never does, and the relay only in its `bookinfo` payload.
    public var tags: [NovelTag]?

    public init(
        id: Int,
        title: String,
        author: String = "",
        category: String = "",
        status: String = "",
        wordCount: String = "",
        updatedAt: String = "",
        intro: String = "",
        coverURL: URL? = nil,
        latestChapter: ChapterLink? = nil,
        recommendations: [NovelSummary] = [],
        tags: [NovelTag]? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.category = category
        self.status = status
        self.wordCount = wordCount
        self.updatedAt = updatedAt
        self.intro = intro
        self.coverURL = coverURL
        self.latestChapter = latestChapter
        self.recommendations = recommendations
        self.tags = tags
    }
}

public struct ChapterLink: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var title: String

    public init(id: Int, title: String) {
        self.id = id
        self.title = title
    }
}

public struct Volume: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var chapters: [ChapterLink]

    public init(id: String, title: String, chapters: [ChapterLink]) {
        self.id = id
        self.title = title
        self.chapters = chapters
    }
}

public struct ChapterContent: Hashable, Codable, Sendable {
    public var novelID: Int
    public var chapterID: Int
    public var title: String
    public var blocks: [Block]
    public var pageCount: Int

    public init(novelID: Int, chapterID: Int, title: String, blocks: [Block], pageCount: Int = 1) {
        self.novelID = novelID
        self.chapterID = chapterID
        self.title = title
        self.blocks = blocks
        self.pageCount = pageCount
    }

    public enum Block: Hashable, Codable, Sendable {
        case paragraph(String)
        case image(URL)
    }

    public var plainText: String {
        blocks.compactMap { block -> String? in
            if case .paragraph(let text) = block { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    public var firstImage: URL? {
        for block in blocks {
            if case .image(let url) = block { return url }
        }
        return nil
    }
}

public struct NovelReview: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var topic: String
    public var author: String
    public var date: String
    public var replyCount: Int

    public init(id: Int, topic: String, author: String, date: String, replyCount: Int = 0) {
        self.id = id
        self.topic = topic
        self.author = author
        self.date = date
        self.replyCount = replyCount
    }
}

/// One row of the signed-in user's shelf.
public struct ShelfEntry: Identifiable, Hashable, Codable, Sendable {
    public var novel: NovelSummary
    /// The chapter the site has recorded for this book, when the shelf lists one.
    public var latestChapter: ChapterLink?

    public var id: Int { novel.id }

    public init(novel: NovelSummary, latestChapter: ChapterLink? = nil) {
        self.novel = novel
        self.latestChapter = latestChapter
    }
}

public struct ReviewPost: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var author: String
    public var date: String
    public var body: String

    public init(id: String, author: String, date: String, body: String) {
        self.id = id
        self.author = author
        self.date = date
        self.body = body
    }
}

public struct LibraryCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    public static let all: [LibraryCategory] = [
        .init(id: 0, name: "全部轻小说"),
        .init(id: 1, name: "电击文库"),
        .init(id: 2, name: "富士见文库"),
        .init(id: 3, name: "角川文库"),
        .init(id: 4, name: "MF文库J"),
        .init(id: 5, name: "Fami通文库"),
        .init(id: 6, name: "GA文库"),
        .init(id: 7, name: "HJ文库"),
        .init(id: 8, name: "一迅社"),
        .init(id: 9, name: "集英社"),
        .init(id: 10, name: "小学馆"),
        .init(id: 11, name: "讲谈社"),
        .init(id: 12, name: "少女文库"),
        .init(id: 13, name: "其他文库"),
    ]
}

public enum RankBoard: String, CaseIterable, Identifiable, Codable, Sendable {
    case dayvisit
    case dayvote
    case weekvisit
    case weekvote
    case monthvisit
    case monthvote
    case allvisit
    case allvote
    case postdate
    case lastupdate
    case goodnum
    case size
    case fullflag
    case anime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dayvisit: return "日点击榜"
        case .dayvote: return "日推荐榜"
        case .weekvisit: return "周点击榜"
        case .weekvote: return "周推荐榜"
        case .monthvisit: return "月点击榜"
        case .monthvote: return "月推荐榜"
        case .allvisit: return "总点击榜"
        case .allvote: return "总推荐榜"
        case .postdate: return "最新入库"
        case .lastupdate: return "最近更新"
        case .goodnum: return "总收藏榜"
        case .size: return "字数排行"
        case .fullflag: return "已完结作品"
        case .anime: return "动画化作品"
        }
    }

    public var symbol: String {
        switch self {
        case .dayvisit, .weekvisit, .monthvisit, .allvisit: return "flame"
        case .dayvote, .weekvote, .monthvote, .allvote: return "hand.thumbsup"
        case .postdate: return "sparkles"
        case .lastupdate: return "clock.arrow.circlepath"
        case .goodnum: return "star"
        case .size: return "textformat.size"
        case .fullflag: return "checkmark.seal"
        case .anime: return "tv"
        }
    }

    public static let primary: [RankBoard] = [.dayvisit, .weekvisit, .monthvisit, .allvisit, .lastupdate, .postdate]
}

public enum HomeSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case hot
    case latest
    case newcomer
    case weekly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hot: return "今日热榜"
        case .latest: return "最近更新"
        case .newcomer: return "新书风云"
        case .weekly: return "每周书单"
        }
    }

    public var subtitle: String {
        switch self {
        case .hot: return "文库今日最受关注"
        case .latest: return "刚刚有新章节上架"
        case .newcomer: return "刚刚入库的新书"
        case .weekly: return "编辑部推荐阅读"
        }
    }

    public var symbol: String {
        switch self {
        case .hot: return "flame.fill"
        case .latest: return "clock.arrow.circlepath"
        case .newcomer: return "sparkles"
        case .weekly: return "books.vertical.fill"
        }
    }

    public var board: RankBoard {
        switch self {
        case .hot: return .dayvisit
        case .latest: return .lastupdate
        case .newcomer: return .postdate
        // "每周书单" is the weekly board; it was pointing at 总收藏榜, so opening it
        // showed an all-time list under a weekly title.
        case .weekly: return .weekvisit
        }
    }
}

public enum BookSource: String, Codable, Sendable {
    case wap
    case desktop
}

public enum Wenku8Error: LocalizedError, Sendable {
    case network(String)
    case parse(String)
    case needLogin
    case unavailable(String)
    case login(String)

    public var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .parse(let message): return message
        case .needLogin: return "该功能需要登录文库账号"
        case .unavailable(let message): return message
        case .login(let message): return message
        }
    }
}

public enum CoverURL {
    public static func image(for aid: Int) -> URL? {
        let group = max(0, aid / 1000)
        return URL(string: "https://img.wenku8.com/image/\(group)/\(aid)/\(aid)s.jpg")
    }

    public static func normalize(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") {
            value = "https:" + value
        }
        if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        return URL(string: value)
    }
}

extension Array where Element == NovelSummary {
    /// Drops repeated book ids while keeping the first occurrence's order.
    ///
    /// SwiftUI's `ForEach` treats a duplicate id as a fatal error, and the data
    /// paths here concatenate several sources (relay, WAP, desktop, yearly
    /// rankings), so any one of them repeating a book would crash the list.
    public func uniquedByID() -> [NovelSummary] {
        var seen = Set<Int>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension Array where Element == ChapterLink {
    /// Drops repeated chapter ids while keeping order. Catalogue pages can repeat
    /// a chapter when a volume spans a page boundary.
    public func uniquedByID() -> [ChapterLink] {
        var seen = Set<Int>()
        return filter { seen.insert($0.id).inserted }
    }
}
