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
        /// The `sort` of the list behind the panel's 「更多」 link, when it has one — that
        /// link is the site's own way of expanding a panel into a full ranking.
        public var moreSort: String?

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
            let moreSort = firstMatch(#"toplist\.php\?sort=([a-z]+)"#, in: body)
            blocks.append(HomeBlock(title: title, novels: novels, moreSort: moreSort))
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

    /// One heading on the tag cloud page, e.g. 幻想系属性.
    public struct TagGroup: Sendable, Identifiable, Hashable {
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
        let headingPattern = #"<td[^>]*class="vcss"[^>]*>\s*([^<]*?)\s*</td>"#
        let chapterPattern = #"<a\s+href="(\d+)\.htm"[^>]*>([^<]{1,80})</a>"#
        guard let headingRegex = try? NSRegularExpression(
                pattern: headingPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let chapterRegex = try? NSRegularExpression(
                pattern: chapterPattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var volumes: [Volume] = []
        var currentTitle = "正文"
        var currentChapters: [ChapterLink] = []
        var seen = Set<Int>()

        // Walk both kinds of marker in document order so a volume heading closes
        // the previous volume and opens the next one.
        var markers: [(location: Int, title: String?, chapter: ChapterLink?)] = []
        for match in headingRegex.matches(in: html, range: range) {
            guard let titleRange = Range(match.range(at: 1), in: html) else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
            markers.append((match.range.location, title.isEmpty ? nil : title, nil))
        }
        for match in chapterRegex.matches(in: html, range: range) {
            guard let cidRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let cid = Int(html[cidRange]) else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
            guard !title.isEmpty, seen.insert(cid).inserted else { continue }
            markers.append((match.range.location, nil, ChapterLink(id: cid, title: title)))
        }
        markers.sort { $0.location < $1.location }

        func flush() {
            guard !currentChapters.isEmpty else { return }
            volumes.append(Volume(id: "\(volumes.count)", title: currentTitle, chapters: currentChapters))
            currentChapters = []
        }

        for marker in markers {
            if let title = marker.title {
                flush()
                currentTitle = title
            } else if let chapter = marker.chapter {
                currentChapters.append(chapter)
            }
        }
        flush()
        return volumes
    }
}
