import Foundation

public enum WAPParser {
    public static let linkPattern = try? NSRegularExpression(
        pattern: #"<a\s+href="(?:[^"]*/)?articleinfo\.php\?id=(\d+)"[^>]*>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Detects the "please log in" card that the site returns for gated pages.
    public static func requiresLogin(_ html: String) -> Bool {
        guard let card = firstMatch(#"<card\s+id="([^"]+)""#, in: html) else { return false }
        return card.contains("login")
    }

    public static func cardTitle(_ html: String) -> String? {
        firstMatch(#"<card[^>]*title="([^"]*)""#, in: html).map { Markup.decodeEntities($0) }
    }

    public static func homeSections(_ html: String) -> [HomeRow] {
        var rows: [HomeRow] = []
        guard let pattern = try? NSRegularExpression(
            pattern: #"【([^】]+)】([^<]*)"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let titleRange = Range(match.range(at: 1), in: html),
                  let fullRange = Range(match.range, in: html) else { continue }
            let title = String(html[titleRange])
            let section: HomeSection
            switch title {
            case let value where value.contains("更新"):
                section = .latest
            case let value where value.contains("新书"):
                section = .newcomer
            case let value where value.contains("书单"):
                section = .weekly
            case let value where value.contains("热"):
                section = .hot
            default:
                continue
            }

            let tail = String(html[fullRange.upperBound...])
            let stopIndex = tail.range(of: "【")?.lowerBound ?? tail.endIndex
            let items = linksIn(String(tail[..<stopIndex]))
            guard !items.isEmpty else { continue }
            if let existing = rows.firstIndex(where: { $0.section == section }) {
                rows[existing].items.append(contentsOf: items)
            } else {
                rows.append(HomeRow(section: section, items: items))
            }
        }
        return rows
    }

    public static func linksIn(_ html: String) -> [NovelSummary] {
        guard let pattern = linkPattern else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [NovelSummary] = []
        var seen = Set<Int>()
        for match in pattern.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html),
                  let id = Int(html[idRange]) else { continue }
            guard seen.insert(id).inserted else { continue }
            let raw = String(html[textRange])
            let title = Markup.normalize(Markup.decodeEntities(raw))
            guard !title.isEmpty else { continue }
            results.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
        }
        return results
    }

    public static func novelDetail(_ html: String, aid: Int) -> NovelDetail {
        let text = html.replacingOccurrences(of: "\r", with: "")
        var detail = NovelDetail(id: aid, title: cardTitle(html) ?? "")
        let body = bodyOnly(text)

        if let match = firstMatch(#"<b>([^<]+)</b><br\s*/?>"#, in: body) {
            detail.title = Markup.decodeEntities(match).trimmingCharacters(in: .whitespaces)
        } else if let cardTitle = cardTitle(html) {
            detail.title = cardTitle
        }

        if let cover = firstMatch(#"<img\s+src="([^"]+)"[^>]*width="150"#, in: body) {
            detail.coverURL = CoverURL.normalize(Markup.decodeEntities(cover))
        }
        if detail.coverURL == nil {
            detail.coverURL = CoverURL.image(for: aid)
        }

        if let value = firstMatch(#"作者:<anchor>([^<]+)<"#, in: body) {
            detail.author = Markup.decodeEntities(value).trimmingCharacters(in: .whitespaces)
        } else if let value = firstMatch(#"作者:<a[^>]*>([^<]+)</a>"#, in: body) {
            detail.author = Markup.decodeEntities(value).trimmingCharacters(in: .whitespaces)
        }

        if let value = firstMatch(#"类别:<a[^>]*>([^<]+)</a>"#, in: body) {
            detail.category = Markup.decodeEntities(value)
        }
        if let value = firstMatch(#"状态:([^<]+)<br"#, in: body) {
            detail.status = Markup.decodeEntities(value).trimmingCharacters(in: .whitespaces)
        }
        if let value = firstMatch(#"字数:([^<]+)<br"#, in: body) {
            detail.wordCount = Markup.decodeEntities(value)
        }
        if let value = firstMatch(#"更新:([^<]+)<br"#, in: body) {
            detail.updatedAt = Markup.decodeEntities(value)
        }

        if let cidText = firstMatch(#"readchapter\.php\?aid=\d+&amp;cid=(\d+)"#, in: body),
           let cid = Int(cidText) {
            let titlePattern = #"readchapter\.php\?aid=\d+&amp;cid=\#(cid)""[^>]*>([^<]+)</a>"#
            let title = firstMatch(titlePattern, in: body).map { Markup.decodeEntities($0) } ?? ""
            detail.latestChapter = ChapterLink(id: cid, title: title)
        }

        if let introStart = body.range(of: "[作品简介]"),
           let end = body.range(of: "<p align=\"center\">", range: introStart.upperBound..<body.endIndex) {
            let raw = String(body[introStart.upperBound..<end.lowerBound])
            detail.intro = paragraphs(from: raw).joined(separator: "\n")
        }

        detail.recommendations = recommendationLinks(in: text)
        return detail
    }

    public static func volumes(_ html: String) -> [Volume] {
        let body = bodyOnly(html)
        var volumes: [Volume] = []
        var current: Volume?

        let pattern = try? NSRegularExpression(
            pattern: #"〖([^〗]+)〗|<a\s+href="readchapter\.php\?aid=(\d+)&amp;cid=(\d+)"[^>]*>([^<]*)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        for match in pattern?.matches(in: body, range: range) ?? [] {
            if match.range(at: 1).location != NSNotFound,
               let titleRange = Range(match.range(at: 1), in: body) {
                if let current, !current.chapters.isEmpty {
                    volumes.append(current)
                }
                let title = Markup.decodeEntities(String(body[titleRange]))
                current = Volume(id: "\(volumes.count)", title: title, chapters: [])
            } else if let cidRange = Range(match.range(at: 3), in: body),
                      let titleRange = Range(match.range(at: 4), in: body),
                      let cid = Int(body[cidRange]) {
                let title = Markup.normalize(Markup.decodeEntities(String(body[titleRange])))
                guard !title.isEmpty else { continue }
                if current == nil {
                    current = Volume(id: "0", title: "正文", chapters: [])
                }
                current?.chapters.append(ChapterLink(id: cid, title: title))
            }
        }
        if let current, !current.chapters.isEmpty {
            volumes.append(current)
        }
        return volumes
    }

    public static func pagination(_ html: String) -> (current: Int, total: Int) {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)/(\d+)\]"#, options: [.dotMatchesLineSeparators]) else {
            return (1, 1)
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let currentRange = Range(match.range(at: 1), in: html),
              let totalRange = Range(match.range(at: 2), in: html) else {
            return (1, 1)
        }
        return (Int(html[currentRange]) ?? 1, Int(html[totalRange]) ?? 1)
    }

    public static func chapterContent(_ html: String, aid: Int, cid: Int) -> ChapterContent {
        let (_, total) = pagination(html)
        var blocks: [ChapterContent.Block] = []

        if let range = html.range(of: "[1/") {
            let headerEnd = html.range(of: "<br/>", options: [], range: range.lowerBound..<html.endIndex)
            if let headerEnd {
                let tail = String(html[headerEnd.upperBound...])
                if let footer = tail.range(of: "<a href=\"readchapter.php?aid=") {
                    let body = String(tail[..<footer.lowerBound])
                    blocks = chapterBlocks(from: body)
                }
            }
        }

        if blocks.isEmpty {
            if html.contains("本章节是纯图片内容") {
                blocks = [.paragraph("本章节是纯图片内容，请在电脑版网页中浏览插图。")]
            } else if let link = firstMatch(
                #"<a href="(https://www\.wenku8\.net/modules/article/reader\.php[^"]*)""#,
                in: html
            ) {
                blocks = [.paragraph("该章节为图片内容，可在电脑版页面查看：\(Markup.decodeEntities(link))")]
            }
        }

        let title = pageTitle(html) ?? ""
        return ChapterContent(novelID: aid, chapterID: cid, title: title, blocks: blocks, pageCount: total)
    }

    static func chapterBlocks(from fragment: String) -> [ChapterContent.Block] {
        var blocks: [ChapterContent.Block] = []
        var buffer = ""
        let tokens = Markup.tokenize(fragment)

        func flush() {
            let text = Markup.normalize(buffer)
            buffer = ""
            guard !text.isEmpty else { return }
            if text.hasPrefix("报时:") { return }
            if text.hasPrefix("[") { return }
            blocks.append(.paragraph(text.replacingOccurrences(of: "\u{3000}", with: "")))
        }

        for token in tokens {
            switch token {
            case .text(let value):
                buffer += Markup.decodeEntities(value)
            case .startTag(let name, let attributes, _):
                switch name {
                case "br", "p", "div":
                    flush()
                case "img":
                    flush()
                    if let src = attributes["src"], let url = CoverURL.normalize(Markup.decodeEntities(src)) {
                        blocks.append(.image(url))
                    }
                default:
                    break
                }
            case .endTag(let name):
                if name == "p" || name == "div" { flush() }
            }
        }
        flush()
        return blocks.filter { block in
            if case .paragraph(let text) = block {
                return !text.isEmpty && !text.contains("轻小说文库") && !text.contains("本章节是纯图片内容")
            }
            return true
        }
    }

    public static func reviews(_ html: String) -> [NovelReview] {
        var reviews: [NovelReview] = []
        let pattern = try? NSRegularExpression(
            pattern: #"<a href="/wap/userinfo\.php\?id=\d+">([^<]*)</a>:\s*<a href="/wap/article/reviewshow\.php\?rid=(\d+)">([^<]*)</a>\s*\[(\d+)回复/([^\]]*)\]"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern?.matches(in: html, range: range) ?? [] {
            guard let idRange = Range(match.range(at: 2), in: html),
                  let rid = Int(html[idRange]),
                  let authorRange = Range(match.range(at: 1), in: html),
                  let topicRange = Range(match.range(at: 3), in: html) else { continue }
            let author = Markup.decodeEntities(String(html[authorRange]))
            let topic = Markup.normalize(Markup.decodeEntities(String(html[topicRange])))
            var replies = 0
            var date = ""
            if let replyRange = Range(match.range(at: 4), in: html) {
                replies = Int(html[replyRange]) ?? 0
            }
            if let dateRange = Range(match.range(at: 5), in: html) {
                date = String(html[dateRange]).trimmingCharacters(in: .whitespaces)
            }
            reviews.append(
                NovelReview(id: rid, topic: topic, author: author, date: date, replyCount: replies)
            )
        }
        return reviews
    }

    public static func reviewPosts(_ html: String) -> (topic: String, posts: [ReviewPost]) {
        let topic = firstMatch(#"主题：([^<]*)<br"#, in: html).map { Markup.decodeEntities($0) } ?? ""
        var posts: [ReviewPost] = []
        let pattern = try? NSRegularExpression(
            pattern: #"<a href="/wap/userinfo\.php\?id=\d+">([^<]*)</a>:\s*(.*?)\[(\d{4}-\d{2}-\d{2})\]"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for (index, match) in (pattern?.matches(in: html, range: range) ?? []).enumerated() {
            guard let authorRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html),
                  let dateRange = Range(match.range(at: 3), in: html) else { continue }
            let author = Markup.decodeEntities(String(html[authorRange]))
            let date = String(html[dateRange])
            let body = paragraphs(from: String(html[bodyRange])).joined(separator: "\n")
            posts.append(ReviewPost(id: "\(index)", author: author, date: date, body: body))
        }
        return (topic, posts)
    }

    public static func libraryCategories(_ html: String) -> [LibraryCategory] {
        var result: [LibraryCategory] = []
        let pattern = try? NSRegularExpression(
            pattern: #"sortlist\.php\?class=(\d+)"[^>]*>([^<]+)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern?.matches(in: html, range: range) ?? [] {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let id = Int(html[idRange]) else { continue }
            let name = Markup.decodeEntities(String(html[nameRange]))
            result.append(LibraryCategory(id: id, name: name))
        }
        return result
    }

    public static func accountName(_ html: String) -> String? {
        firstMatch(#"您好!([^,<]+),"#, in: html).map { Markup.decodeEntities($0) }
            .flatMap { $0 == "游客" ? nil : $0 }
    }

    // MARK: - helpers

    static func pageTitle(_ html: String) -> String? {
        cardTitle(html)
    }

    static func bodyOnly(_ html: String) -> String {
        guard let start = html.range(of: "<card") else { return html }
        guard let end = html.range(of: "</card>", options: [], range: start.lowerBound..<html.endIndex) else {
            return String(html[start.lowerBound...])
        }
        return String(html[start.upperBound..<end.lowerBound])
    }

    static func paragraphs(from fragment: String) -> [String] {
        Markup.lines(from: fragment).filter { !$0.isEmpty }
    }

    static func recommendationLinks(in html: String) -> [NovelSummary] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"<a href="(/book/(\d+)\.htm)"[^>]*title="([^"]*)""#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [NovelSummary] = []
        var seen = Set<Int>()
        for match in pattern.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 2), in: html),
                  let titleRange = Range(match.range(at: 3), in: html),
                  let id = Int(html[idRange]),
                  seen.insert(id).inserted else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
            results.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
        }
        return results
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }
}

public struct HomeRow: Identifiable, Hashable, Sendable {
    public var section: HomeSection
    public var items: [NovelSummary]

    public var id: String { section.id }

    public init(section: HomeSection, items: [NovelSummary]) {
        self.section = section
        self.items = items
    }
}
