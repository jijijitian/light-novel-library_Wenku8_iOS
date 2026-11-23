import Foundation

public enum DesktopParser {
    /// The desktop site serves a "本站正式关闭" notice in place of list pages for
    /// anonymous clients. Treating that page as a parse failure keeps the UI from
    /// presenting an empty ranking as if the site had no books.
    public static func isPlaceholder(_ html: String) -> Bool {
        html.contains("本站正式关闭") || html.contains("感谢每一位朋友的支持")
    }

    /// Extracts novel cards from the desktop list markup: a cover link plus title.
    public static func novelCards(_ html: String) -> [NovelSummary] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a href="/book/(\d+)\.htm"[^>]*title="([^"]*)""#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [NovelSummary] = []
        var seen = Set<Int>()
        for match in regex.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let id = Int(html[idRange]),
                  seen.insert(id).inserted else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
            guard !title.isEmpty, title != "#" else { continue }
            results.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
        }
        return results
    }

    /// A tag's book list (`/modules/article/tags.php?t=…`).
    ///
    /// Each card carries its own `Tags:` line, so the rows come back with their tags; the
    /// page count sits in `<em id="pagestats">1/60</em>`.
    public static func tagPage(_ html: String) -> (novels: [NovelSummary], totalPages: Int) {
        var totalPages = 1
        if let stats = firstMatch(#"id="pagestats">\d+/(\d+)<"#, in: html), let value = Int(stats) {
            totalPages = max(1, value)
        }

        // Cards are laid out at a fixed width; splitting on it keeps each book's tags with
        // that book instead of matching across neighbours.
        let cards = html.components(separatedBy: "width:373px")
        let regex = try? NSRegularExpression(
            pattern: #"<a href="/book/(\d+)\.htm" title="([^"]*)""#,
            options: [.dotMatchesLineSeparators]
        )
        var novels: [NovelSummary] = []
        var seen = Set<Int>()
        for card in cards.dropFirst() {
            let range = NSRange(card.startIndex..<card.endIndex, in: card)
            guard let match = regex?.firstMatch(in: card, range: range),
                  let idRange = Range(match.range(at: 1), in: card),
                  let titleRange = Range(match.range(at: 2), in: card),
                  let id = Int(card[idRange]),
                  seen.insert(id).inserted else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(card[titleRange])))
            guard !title.isEmpty else { continue }
            var tags: [NovelTag]?
            if let rawTags = firstMatch(#"Tags:<span[^>]*>([^<]*)</span>"#, in: card) {
                tags = NovelTag.split(Markup.decodeEntities(rawTags))
            }
            novels.append(NovelSummary(
                id: id,
                title: title,
                coverURL: CoverURL.image(for: id),
                tags: tags
            ))
        }
        return (novels, totalPages)
    }

    /// One of the homepage's blocks, e.g. 新书风云榜.
    public struct HomeBlock: Sendable, Identifiable, Hashable, Codable {
        public var title: String
        public var novels: [NovelSummary]
        /// The target of the panel's 「更多」 link, when it has one — that link is the
        /// site's own way of expanding a panel into a full list. It points at either
        /// `toplist.php?sort=…` or `articlelist.php?fullflag=1`.
        public var moreURL: String?

        public var id: String { title }
    }

    /// The homepage's book blocks.
    ///
    /// The page is built from `<div class="block">` panels whose title sits in
    /// `blocktitle`; the panel below it holds either cover cards (`title` on the anchor) or
    /// a list of update rows (`《书名》` as the anchor text). Both shapes are read, and blocks
    /// with no books — announcements, banners — drop out on their own.
    ///
    /// The homepage needs a session: anonymous visitors are redirected to the login form.
    public static func homeBlocks(_ html: String) -> [HomeBlock] {
        let titleRegex = try? NSRegularExpression(
            pattern: #"<div class="blocktitle">(.*?)</div>"#,
            options: [.dotMatchesLineSeparators]
        )
        let ns = html as NSString
        let matches = titleRegex?.matches(
            in: html,
            range: NSRange(location: 0, length: ns.length)
        ) ?? []
        guard !matches.isEmpty else { return [] }

        var blocks: [HomeBlock] = []
        for (index, match) in matches.enumerated() {
            let rawTitle = ns.substring(with: match.range(at: 1))
            // Some titles wrap an explanatory link — 「…( 查看 榜单 )」 — so the bracketed
            // tail is dropped rather than shown inside a section header.
            let full = Markup.normalize(Markup.decodeEntities(Markup.plainText(rawTitle)))
            let title = full
                .split(whereSeparator: { $0 == "(" || $0 == "（" })
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                ?? full
            guard !title.isEmpty else { continue }

            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count
                ? matches[index + 1].range.location
                : ns.length
            guard end > start else { continue }
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            let novels = homeBlockNovels(body)
            guard !novels.isEmpty else { continue }
            // The link can sit inside the title — 完本轻小说推广区 puts 「更多完本轻小说」 in its
            // own heading — and the site writes some tags in upper case, hence `(?i)`.
            let moreURL = firstMatch(
                #"(?i)<a[^>]+href="([^"]*(?:toplist|articlelist)\.php[^"]*)"[^>]*>[^<]*更多"#,
                in: rawTitle + body
            )
            blocks.append(HomeBlock(title: title, novels: novels, moreURL: moreURL))
        }
        return blocks
    }

    /// Books inside one homepage panel, in page order.
    private static func homeBlockNovels(_ body: String) -> [NovelSummary] {
        var results: [NovelSummary] = []
        var seen = Set<Int>()
        var ordered: [Int] = []
        var titles: [Int: String] = [:]

        // Cover cards carry the title on the anchor.
        let titled = try? NSRegularExpression(
            pattern: #"<a href="/book/(\d+)\.htm"[^>]*title="([^"]*)""#,
            options: [.dotMatchesLineSeparators]
        )
        let ns = body as NSString
        for match in titled?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let id = Int(ns.substring(with: match.range(at: 1))),
                  seen.insert(id).inserted else { continue }
            let title = Markup.normalize(Markup.decodeEntities(ns.substring(with: match.range(at: 2))))
            guard !title.isEmpty else { continue }
            ordered.append(id)
            titles[id] = title
        }

        // Update rows carry it as the anchor text instead.
        let plain = try? NSRegularExpression(
            pattern: #"<a [^>]*href="/book/(\d+)\.htm"[^>]*>([^<]*)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        for match in plain?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let id = Int(ns.substring(with: match.range(at: 1))),
                  titles[id] == nil else { continue }
            let raw = Markup.normalize(
                Markup.decodeEntities(ns.substring(with: match.range(at: 2)))
            )
            let title = raw.trimmingCharacters(in: CharacterSet(charactersIn: "《》 "))
            guard !title.isEmpty, title != "#" else { continue }
            seen.insert(id)
            ordered.append(id)
            titles[id] = title
        }

        for id in ordered {
            guard let title = titles[id] else { continue }
            results.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
        }
        return results
    }

    /// The `作品Tags` line on a book's page.
    ///
    /// It reads `<b>作品Tags：校园 斗智 青春</b>`; the line is absent on pages the site serves
    /// without it, so a nil result is normal rather than an error.
    public static func tags(_ html: String) -> [NovelTag]? {
        guard let raw = firstMatch(#"作品Tags：([^<]*)<"#, in: html) else { return nil }
        return NovelTag.split(Markup.decodeEntities(raw))
    }

    /// A delisted book's catalogue, read from the one page that still renders it.
    ///
    /// `/novel/<group>/<aid>/index.htm` keeps the full table of contents even after the book
    /// is taken down. The download endpoint wants a volume id, which that page never prints —
    /// but the volume id is one less than its first chapter's id, so the downloads can be
    /// addressed from the chapter ids alone.
    /// A chapter's illustrations from its desktop page.
    ///
    /// The mobile endpoint strips images entirely: a book's 插图 chapter comes back from it
    /// with no pictures at all, so the desktop page is the only place they can be read. Each
    /// picture sits in `<div class="divimage"><a href="…"><img src="…">`.
    public static func chapterImages(_ html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<div class="divimage"><a href="([^"]+)"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let ns = html as NSString
        var urls: [URL] = []
        var seen = Set<String>()
        let range = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: html, range: range) {
            let raw = ns.substring(with: match.range(at: 1))
            guard seen.insert(raw).inserted else { continue }
            // The page writes protocol-relative hosts for some mirrors.
            let absolute = raw.hasPrefix("//") ? "https:" + raw : raw
            guard let url = URL(string: absolute) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// True when the book page carries the delisting notice.
    ///
    /// The page renders 「因版权问题，文库不再提供该小说的在线阅读与下载服务！」 in place of the
    /// catalogue. The wording is stable enough to match on its opening phrase rather than the
    /// whole sentence.
    public static func isDelisted(_ html: String) -> Bool {
        html.contains("因版权问题") && html.contains("不再提供该小说")
    }

    /// The site's explanation of its tag service, shown below the cloud.
    public struct TagGuide: Sendable, Hashable, Codable {
        public struct Entry: Sendable, Hashable, Codable, Identifiable {
            public var tag: String
            public var text: String

            public var id: String { tag }
        }

        public var title: String
        public var intro: [String]
        public var entries: [Entry]
    }

    /// One column of the heat ranking page (`/top.php`), e.g. 总热度榜.
    public struct HeatBoard: Sendable, Identifiable, Hashable, Codable {
        public var title: String
        public var novels: [NovelSummary]

        public var id: String { title }
    }

    /// The heat ranking page's columns.
    ///
    /// Each is `<div class="blockcaption">总热度榜</div>` followed by a `ultop` list of book
    /// links; the page carries twenty of them, one per library and per measure.
    public static func heatBoards(_ html: String) -> [HeatBoard] {
        let captionRegex = try? NSRegularExpression(
            pattern: #"class="blockcaption">([^<]*)</div>"#,
            options: [.dotMatchesLineSeparators]
        )
        let ns = html as NSString
        let matches = captionRegex?.matches(
            in: html,
            range: NSRange(location: 0, length: ns.length)
        ) ?? []
        guard !matches.isEmpty else { return [] }

        var boards: [HeatBoard] = []
        for (index, match) in matches.enumerated() {
            let title = Markup.normalize(
                Markup.decodeEntities(ns.substring(with: match.range(at: 1)))
            )
            guard !title.isEmpty else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard end > start else { continue }
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            let novels = heatNovels(body)
            guard !novels.isEmpty else { continue }
            boards.append(HeatBoard(title: title, novels: novels))
        }
        return boards
    }

    private static func heatNovels(_ body: String) -> [NovelSummary] {
        var results: [NovelSummary] = []
        var seen = Set<Int>()
        let regex = try? NSRegularExpression(
            pattern: #"<a href="/book/(\d+)\.htm" title="([^"]*)""#,
            options: [.dotMatchesLineSeparators]
        )
        let ns = body as NSString
        for match in regex?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let id = Int(ns.substring(with: match.range(at: 1))),
                  seen.insert(id).inserted else { continue }
            let title = Markup.normalize(Markup.decodeEntities(ns.substring(with: match.range(at: 2))))
            guard !title.isEmpty else { continue }
            results.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
        }
        return results
    }

    /// One heading on the tag cloud page, e.g. 幻想系属性.
    public struct TagGroup: Sendable, Identifiable, Hashable, Codable {
        public var title: String
        public var tags: [String]

        public var id: String { title }
    }

    /// The tag cloud, split into the headings the site gives it.
    ///
    /// The page is a list of `<li>` rows: one row is a heading (`日常系属性Tags：`), the rows
    /// after it are that heading's tags. Reading it as a flat list loses the grouping the
    /// site uses to make a hundred tags browsable.
    public static func tagCloudGroups(_ html: String) -> [TagGroup] {
        let rowRegex = try? NSRegularExpression(
            pattern: #"<li>(.*?)</li>"#,
            options: [.dotMatchesLineSeparators]
        )
        let tagRegex = try? NSRegularExpression(
            pattern: #"<a href=tags\.php\?t=[^>]*>([^<]+)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var groups: [TagGroup] = []
        var current: TagGroup?

        for match in rowRegex?.matches(in: html, range: range) ?? [] {
            guard let bodyRange = Range(match.range(at: 1), in: html) else { continue }
            let body = String(html[bodyRange])

            if body.contains("tags.php?t=") {
                let bodyNS = body as NSString
                let bodyRangeNS = NSRange(location: 0, length: bodyNS.length)
                for tagMatch in tagRegex?.matches(in: body, range: bodyRangeNS) ?? [] {
                    let name = Markup.normalize(
                        Markup.decodeEntities(bodyNS.substring(with: tagMatch.range(at: 1)))
                    )
                    guard !name.isEmpty else { continue }
                    if current == nil { current = TagGroup(title: "标签", tags: []) }
                    current?.tags.append(name)
                }
            } else {
                // A heading: flush whatever was being collected.
                if let finished = current, !finished.tags.isEmpty {
                    groups.append(finished)
                }
                current = nil
                let text = Markup.normalize(
                    Markup.decodeEntities(Markup.plainText(body))
                )
                guard text.hasSuffix("：") || text.hasSuffix(":") else { continue }
                var title = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
                if title.hasSuffix("Tags") {
                    title = String(title.dropLast(4)).trimmingCharacters(in: .whitespaces)
                }
                guard !title.isEmpty else { continue }
                current = TagGroup(title: title, tags: [])
            }
        }
        if let finished = current, !finished.tags.isEmpty {
            groups.append(finished)
        }
        return groups
    }

    /// The 「检索服务相关说明和使用指南」 block that sits under the cloud.
    ///
    /// Its opening paragraphs are one `<b>` split by `<br>`, and each tag it explains is an
    /// `<li><span>青春Tag：</span><br>…</li>`.
    public static func tagGuide(_ html: String) -> TagGuide? {
        guard let captionRange = html.range(
            of: #"<caption>轻小说Tags检索服务相关说明和使用指南</caption>"#,
            options: .regularExpression
        ) else { return nil }
        let title = "轻小说Tags检索服务相关说明和使用指南"
        let rest = String(html[captionRange.upperBound...])

        var intro: [String] = []
        if let start = rest.range(of: "<b>"), let end = rest.range(of: "</b>") {
            let body = String(rest[start.upperBound..<end.lowerBound])
            intro = body
                .components(separatedBy: "<br>")
                .map { line in
                    // The link inside the first paragraph points at the site's discussion
                    // thread; dropping it would leave the brackets that wrapped it.
                    let stripped = line
                        .replacingOccurrences(
                            of: #"<a[^>]*>.*?</a>"#,
                            with: "",
                            options: .regularExpression
                        )
                        .replacingOccurrences(of: "()", with: "")
                        .replacingOccurrences(of: "（）", with: "")
                    return Markup.normalize(Markup.decodeEntities(Markup.plainText(stripped)))
                }
                .filter { !$0.isEmpty }
        }

        var entries: [TagGuide.Entry] = []
        if let listStart = rest.range(of: #"<ul class="ulli">"#),
           let listEnd = rest.range(of: "</ul>", range: listStart.upperBound..<rest.endIndex) {
            let list = String(rest[listStart.upperBound..<listEnd.lowerBound])
            for match in regexMatches(#"<li>\s*<span>([^<]*)</span>(?:<br>)?([\s\S]*?)</li>"#, in: list) {
                guard match.count == 2 else { continue }
                var tag = Markup.normalize(Markup.decodeEntities(match[0]))
                tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                if tag.hasSuffix("Tag") { tag = String(tag.dropLast(3)) }
                let text = Markup.normalize(Markup.decodeEntities(Markup.plainText(match[1])))
                guard !tag.isEmpty, !text.isEmpty else { continue }
                entries.append(TagGuide.Entry(tag: tag, text: text))
            }
        }

        guard !intro.isEmpty || !entries.isEmpty else { return nil }
        return TagGuide(title: title, intro: intro, entries: entries)
    }

    /// Every capture group, one array per match.
    private static func regexMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { index in
                match.range(at: index).location == NSNotFound
                    ? ""
                    : ns.substring(with: match.range(at: index))
            }
        }
    }

    /// The tag names listed on the site's tag cloud page.
    ///
    /// Its links are written without quotes — `<a href=tags.php?t=青春>青春</a>` — so the
    /// visible text is what gets read rather than the href.
    public static func tagCloud(_ html: String) -> [String] {
        let regex = try? NSRegularExpression(
            pattern: #"<a href=tags\.php\?t=[^>]*>([^<]+)</a>"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var names: [String] = []
        var seen = Set<String>()
        for match in regex?.matches(in: html, range: range) ?? [] {
            guard let textRange = Range(match.range(at: 1), in: html) else { continue }
            let name = Markup.normalize(Markup.decodeEntities(String(html[textRange])))
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    public static func novelDetail(_ html: String, aid: Int) -> NovelDetail {
        var detail = NovelDetail(id: aid, title: "")
        if let title = firstMatch(#"<b>([^<]+)</b>\[\s*<a"#, in: html) {
            detail.title = Markup.decodeEntities(title).trimmingCharacters(in: .whitespaces)
        } else if let title = firstMatch(#"<title>([^<]+?)\s*-\s*[^-]*轻小说文库</title>"#, in: html) {
            detail.title = Markup.decodeEntities(title).trimmingCharacters(in: .whitespaces)
        }

        detail.coverURL = firstMatch(#"<img src="([^"]+)"[^>]*width="168""#, in: html)
            .flatMap { CoverURL.normalize(Markup.decodeEntities($0)) } ?? CoverURL.image(for: aid)

        if let author = firstMatch(#"小说作者：([^<]+)</td>"#, in: html) {
            detail.author = Markup.decodeEntities(author).trimmingCharacters(in: .whitespaces)
        }
        if let category = firstMatch(#"文库分类：([^<]+)</td>"#, in: html) {
            detail.category = Markup.decodeEntities(category)
        }
        if let status = firstMatch(#"文章状态：([^<]+)</td>"#, in: html) {
            detail.status = Markup.decodeEntities(status)
        }
        if let intro = firstMatch(#"内容简介：</span><br /><span style="font-size:14px;">(.*?)</span>"#, in: html) {
            detail.intro = WAPParser.paragraphs(from: intro).joined(separator: "\n")
        }
        if let match = firstMatch(#"(?:href=")?(/novel/\d+/\d+/index\.htm)"#, in: html), !match.isEmpty {
            detail.latestChapter = nil
        }
        return detail
    }

    /// Returns the first `count` capture groups of the first match.
    static func firstMatchGroups(_ pattern: String, in text: String, count: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for index in 1...max(1, count) {
            guard match.numberOfRanges > index,
                  let found = Range(match.range(at: index), in: text) else { return nil }
            groups.append(String(text[found]))
        }
        return groups
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

    /// One of the site's shelf groups.
    ///
    /// The desktop shelf paginates by group: `bookcase.php?classid=<n>`, where 0 is
    /// 默认书架 and 1…5 are 第1…5组书架. An account that never used groups has
    /// everything in 0.
    public struct ShelfGroup: Identifiable, Hashable, Sendable {
        public var classID: Int
        public var title: String
        public var count: Int

        public var id: Int { classID }

        public init(classID: Int, title: String, count: Int) {
            self.classID = classID
            self.title = title
            self.count = count
        }
    }

    /// The groups every account has, whether or not a page could be parsed.
    ///
    /// The site's shelf groups are fixed, so they are declared rather than scraped.
    ///
    /// Every account sees 默认书架 plus 第1…5组书架 in the same order; only the counts
    /// change. Scraping them bought nothing and cost a parse that could silently
    /// produce garbage (a second dropdown on the page once leaked "移到默认书架" in
    /// as a group name). Counts are filled in at runtime from the page's "本组有 N 本"
    /// line for whichever group was just loaded, and cached locally otherwise.
    public static let fixedShelfGroups: [ShelfGroup] = [0, 1, 2, 3, 4, 5].map { index in
        ShelfGroup(
            classID: index,
            title: index == 0 ? "默认书架" : "第\(index)组书架",
            count: 0
        )
    }

    /// The per-group count the page reports for the group it rendered, or `nil`
    /// when the summary line is absent.
    public static func renderedGroupCount(_ html: String) -> Int? {
        guard let raw = firstMatch(#"本组有\s*(\d+)\s*本"#, in: html) else { return nil }
        return Int(raw)
    }

    /// Which group the page was rendered for, from its `selected` option.
    public static func renderedGroupClassID(_ html: String) -> Int? {
        guard let raw = firstMatch(
            #"<option value="(\d+)"\s+selected="selected">"#,
            in: html
        ) else { return nil }
        return Int(raw)
    }

    /// The shelf's own id (`bid`) for a novel (`aid`).
    ///
    /// The shelf page identifies each row by `bid` in the `checkid[]` checkbox while
    /// linking with `aid`; moving a book between groups needs the `bid`.
    public static func bookcaseBid(forAid aid: Int, in html: String) -> Int? {
        let pattern = #"name="checkid\[\]"\s+value="(\d+)"[^<]*<[^>]*>?[\s\S]{0,400}?readbookcase\.php\?aid=\#(aid)\b"#
        if let raw = firstMatch(pattern, in: html), let bid = Int(raw) { return bid }
        // Fall back to a row scan, which does not depend on the exact intervening markup.
        for row in html.components(separatedBy: "<tr") {
            guard row.contains("aid=\(aid)") || row.contains("aid=\(aid)&") else { continue }
            guard let raw = firstMatch(#"name="checkid\[\]"\s+value="(\d+)""#, in: row) else { continue }
            return Int(raw)
        }
        return nil
    }

    /// Extracts the signed-in user's shelf from `/modules/article/bookcase.php`.
    ///
    /// The desktop shelf is a table whose rows look like
    ///
    /// ```html
    /// <input type="checkbox" name="checkid[]" value="<bid>">
    /// <a href="…readbookcase.php?aid=<aid>&bid=<bid>">书名</a>
    /// <td><a href="authors…">作者</a></td>
    /// <a href="…readbookcase.php?aid=<aid>&bid=<bid>&cid=<cid>">最新章节</a>
    /// ```
    ///
    /// It does *not* link to `/book/<aid>.htm`, which is why parsing it with the
    /// generic card extractor returned an empty shelf even though the account has
    /// books. The `cid` is the chapter the reader last opened, so it is preserved.
    public static func bookcase(_ html: String) -> [ShelfEntry] {
        // Pages are GBK-decoded before they get here, so `&` may appear encoded.
        let rowPattern = #"name="checkid\[\]"\s+value="(\d+)""#
        guard let rowRegex = try? NSRegularExpression(
            pattern: rowPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        var entries: [ShelfEntry] = []
        let rows = html.components(separatedBy: "<tr")
        for row in rows {
            let range = NSRange(row.startIndex..<row.endIndex, in: row)
            guard rowRegex.firstMatch(in: row, range: range) != nil else { continue }

            let bookPattern = #"readbookcase\.php\?aid=(\d+)(?:&amp;|&)bid=\d+"[^>]*>([^<]{1,200})</a>"#
            guard let aidText = firstMatch(bookPattern, in: row),
                  let aid = Int(aidText) else { continue }

            let titlePattern = #"readbookcase\.php\?aid=\d+(?:&amp;|&)bid=\d+"[^>]*>([^<]{1,200})</a>"#
            let rawTitle = firstMatch(titlePattern, in: row) ?? ""
            let title = Markup.normalize(Markup.decodeEntities(rawTitle))
            guard !title.isEmpty else { continue }

            let author = firstMatch(#"authorarticle\.php\?author=([^"&>]{1,60})"#, in: row)
                .map { Markup.normalize(Markup.decodeEntities($0)) }

            let latestChapter: ChapterLink? = {
                // Group 1 is the cid, group 2 the visible chapter title; both sit in
                // the same anchor, so they must be captured together.
                let pattern = #"readbookcase\.php\?aid=\d+(?:&amp;|&)bid=\d+(?:&amp;|&)cid=(\d+)"[^>]*>([^<]{1,200})</a>"#
                guard let match = firstMatchGroups(pattern, in: row, count: 2),
                      let cid = Int(match[0]) else { return nil }
                let title = Markup.normalize(Markup.decodeEntities(match[1]))
                return ChapterLink(id: cid, title: title)
            }()

            entries.append(ShelfEntry(
                novel: NovelSummary(
                    id: aid,
                    title: title,
                    author: author,
                    coverURL: CoverURL.image(for: aid)
                ),
                latestChapter: latestChapter
            ))
        }

        // One book per aid, keeping the first occurrence.
        var seen = Set<Int>()
        return entries.filter { seen.insert($0.novel.id).inserted }
    }

    /// Extracts the desktop catalogue (`/novel/<group>/<aid>/index.htm`).
    ///
    /// The WAP catalogue endpoint answers "对不起，该文章不存在！" for some books that
    /// the desktop catalogue still lists in full — 青春猪头少年 (aid 1614) is one —
    /// so this is the fallback that keeps their chapter list reachable.
    ///
    /// Volume headings live in `<td class="vcss">` rows and chapters are
    /// `<a href="<cid>.htm">title</a>`. Books without volume headings keep their
    /// chapters in `<td class="css">`; both are handled.
    public static func volumes(_ html: String) -> [Volume] {
        // The row also carries the volume's download id, `vid="14835"`, which is what the
        // pack endpoint takes. It is the only place the id is printed for a book whose
        // download page has been taken down.
        // The attributes are matched one at a time: a lazy `[^>]*?` before an optional
        // group lets the group be skipped, which silently dropped the id and left every
        // volume numbered from zero.
        let headingPattern = #"<td[^>]*class="vcss"[^>]*?vid="(\d+)"[^>]*>\s*([^<]*?)\s*</td>"#
        let chapterPattern = #"<a\s+href="(\d+)\.htm"[^>]*>([^<]{1,80})</a>"#
        guard let headingRegex = try? NSRegularExpression(
                pattern: headingPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let chapterRegex = try? NSRegularExpression(
                pattern: chapterPattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var volumes: [Volume] = []
        var currentTitle = "正文"
        var currentVID: Int?
        var currentChapters: [ChapterLink] = []
        var seen = Set<Int>()

        // Walk both kinds of marker in document order so a volume heading closes
        // the previous volume and opens the next one.
        var markers: [(location: Int, title: String?, vid: Int?, chapter: ChapterLink?)] = []
        for match in headingRegex.matches(in: html, range: range) {
            guard let titleRange = Range(match.range(at: 2), in: html) else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
            var vid: Int?
            if match.range(at: 1).location != NSNotFound,
               let vidRange = Range(match.range(at: 1), in: html) {
                vid = Int(html[vidRange])
            }
            markers.append((match.range.location, title.isEmpty ? nil : title, vid, nil))
        }
        for match in chapterRegex.matches(in: html, range: range) {
            guard let cidRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let cid = Int(html[cidRange]) else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
            guard !title.isEmpty, seen.insert(cid).inserted else { continue }
            markers.append((match.range.location, nil, nil, ChapterLink(id: cid, title: title)))
        }
        markers.sort { $0.location < $1.location }

        func flush() {
            guard !currentChapters.isEmpty else { return }
            // The page's own id when it has one; a book without volume headings keeps its
            // chapters together under an id the caller never downloads by.
            let identifier = currentVID.map(String.init) ?? "\(volumes.count)"
            volumes.append(Volume(id: identifier, title: currentTitle, chapters: currentChapters))
            currentChapters = []
        }

        for marker in markers {
            if let title = marker.title {
                flush()
                currentTitle = title
                currentVID = marker.vid
            } else if let chapter = marker.chapter {
                currentChapters.append(chapter)
            }
        }
        flush()
        return volumes
    }
}
