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

    /// Reads the group selector from the shelf page.
    ///
    /// ```html
    /// <select name="classlist" onchange="…bookcase.php?classid='+this.value;">
    ///   <option value="0" selected="selected">默认书架</option>
    ///   <option value="1">第1组书架</option>
    /// ```
    ///
    /// The per-group counts come from the summary line
    /// （"已收藏 14 本，本组有 14 本"）, so only the selected group has a real count;
    /// the rest report 0 rather than a guess.
    public static func shelfGroups(_ html: String) -> [ShelfGroup] {
        let pattern = #"<option value="(\d+)"[^>]*>([^<]{1,20})</option>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return [] }

        let currentTitle = currentGroupTitle(html)
        let currentCount = currentGroupCount(html)

        var groups: [ShelfGroup] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let classID = Int(html[idRange]) else { continue }
            let title = Markup.normalize(String(html[titleRange]))
            let isCurrent = title == currentTitle
            groups.append(ShelfGroup(
                classID: classID,
                title: title,
                count: isCurrent ? currentCount : 0
            ))
        }
        return groups
    }

    /// Name of the group the page was rendered for, from its `selected` option.
    static func currentGroupTitle(_ html: String) -> String? {
        firstMatchGroups(#"<option value="\d+"\s+selected="selected">([^<]{1,20})</option>"#, in: html, count: 1)
            .map { Markup.normalize($0[0]) }
    }

    /// The "本组有 N 本" figure from the shelf summary line.
    static func currentGroupCount(_ html: String) -> Int {
        guard let raw = firstMatch(#"本组有\s*(\d+)\s*本"#, in: html) else { return 0 }
        return Int(raw) ?? 0
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
