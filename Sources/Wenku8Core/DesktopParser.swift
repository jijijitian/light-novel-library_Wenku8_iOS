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
