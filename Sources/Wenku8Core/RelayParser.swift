import Foundation

/// Parses the relay's actual wire formats.
///
/// These were captured from the live service, and they differ from the desktop
/// client's XML in three ways that matter:
///
/// * book metadata is `<data name="Title" value="…"/>` (or CDATA for long text),
///   not `<title>…</title>`;
/// * lists are `<result><item aid='…'><data …/></item></result>`;
/// * a chapter body is **plain text**, not XML;
/// * the catalogue is `<package><volume vid="…">…<chapter cid="…">…</volume>`.
public enum RelayParser {
    // MARK: - Elements

    /// One `<item aid>` / `<data name>` node flattened into a lookup.
    private struct Record {
        var attributes: [String: String] = [:]
        var children: [Record] = []

        func value(_ name: String) -> String? {
            for child in children where child.attributes["name"] == name {
                if let value = child.attributes["value"], !value.isEmpty { return value }
                if let text = child.attributes["__text"], !text.isEmpty { return text }
            }
            return nil
        }

        func elementValue(_ name: String) -> String? {
            for child in children where child.name == name {
                if let text = child.attributes["__text"], !text.isEmpty { return text }
            }
            return nil
        }

        var name: String { attributes["__name"] ?? "" }
    }

    /// Lightweight XML reader: enough for the relay's regular, attribute-driven
    /// documents and tolerant of the stray `<?xl` typo one endpoint returns.
    private static func parse(_ xml: String) -> [Record] {
        var stack: [Record] = [Record()]
        var index = xml.startIndex

        func appendText(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !stack.isEmpty else { return }
            var top = stack[stack.count - 1]
            let existing = top.attributes["__text"] ?? ""
            top.attributes["__text"] = existing.isEmpty ? trimmed : existing + " " + trimmed
            stack[stack.count - 1] = top
        }

        while index < xml.endIndex {
            let character = xml[index]
            if character != "<" {
                var text = ""
                while index < xml.endIndex, xml[index] != "<" {
                    text.append(xml[index])
                    index = xml.index(after: index)
                }
                appendText(text)
                continue
            }

            // CDATA
            if xml[index...].hasPrefix("<![CDATA[") {
                index = xml.index(index, offsetBy: 9)
                var cdata = ""
                while index < xml.endIndex, !xml[index...].hasPrefix("]]>") {
                    cdata.append(xml[index])
                    index = xml.index(after: index)
                }
                if index < xml.endIndex {
                    index = xml.index(index, offsetBy: 3, limitedBy: xml.endIndex) ?? xml.endIndex
                }
                appendText(cdata)
                continue
            }

            // comment / declaration / doctype
            if xml[index...].hasPrefix("<!--") {
                if let end = xml.range(of: "-->", range: index..<xml.endIndex) {
                    index = end.upperBound
                } else {
                    index = xml.endIndex
                }
                continue
            }
            if xml[index...].hasPrefix("<?") || xml[index...].hasPrefix("<!") {
                if let end = xml.range(of: ">", range: index..<xml.endIndex) {
                    index = end.upperBound
                } else {
                    index = xml.endIndex
                }
                continue
            }

            guard let tagEnd = xml.range(of: ">", range: index..<xml.endIndex) else {
                index = xml.endIndex
                continue
            }
            let inner = String(xml[xml.index(after: index)..<tagEnd.lowerBound])
            let selfClosing = inner.hasSuffix("/")
            let body = selfClosing ? String(inner.dropLast()) : inner
            let isClosing = body.hasPrefix("/")
            index = tagEnd.upperBound

            if isClosing {
                if stack.count > 1 {
                    let closed = stack.removeLast()
                    stack[stack.count - 1].children.append(closed)
                }
                continue
            }

            let record = parseTag(body)
            stack.append(record)
            if selfClosing {
                let closed = stack.removeLast()
                if !stack.isEmpty { stack[stack.count - 1].children.append(closed) }
            }
        }
        // Unclosed elements still contribute their children.
        while stack.count > 1 {
            let closed = stack.removeLast()
            stack[stack.count - 1].children.append(closed)
        }
        return stack[0].children
    }

    private static func parseTag(_ body: String) -> Record {
        var attributes: [String: String] = [:]
        var name = ""
        var chars = Array(body)
        var i = 0
        while i < chars.count, !chars[i].isWhitespace, chars[i] != "/" {
            name.append(chars[i])
            i += 1
        }
        attributes["__name"] = name

        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            var key = ""
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace {
                key.append(chars[i])
                i += 1
            }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] == "=" else {
                if key.isEmpty { i += 1 }
                continue
            }
            i += 1
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            var value = ""
            if chars[i] == "\"" || chars[i] == "'" {
                let quote = chars[i]
                i += 1
                while i < chars.count, chars[i] != quote {
                    value.append(chars[i])
                    i += 1
                }
                if i < chars.count { i += 1 }
            } else {
                while i < chars.count, !chars[i].isWhitespace {
                    value.append(chars[i])
                    i += 1
                }
            }
            if !key.isEmpty {
                attributes[key] = decodeEntities(value)
            }
        }
        return Record(attributes: attributes)
    }

    private static func decodeEntities(_ value: String) -> String {
        Markup.decodeEntities(value)
    }

    /// All `<item>` nodes of a `<result>`/`<metadata>` document.
    private static func items(_ xml: String) -> [Record] {
        let roots = parse(xml)
        var found: [Record] = []
        func walk(_ records: [Record]) {
            for record in records {
                if record.name == "item" { found.append(record) }
                walk(record.children)
            }
        }
        walk(roots)
        return found
    }

    // MARK: - Books

    public static func summaries(_ xml: String) -> [NovelSummary] {
        var results: [NovelSummary] = []
        for item in items(xml) {
            guard let aidText = item.attributes["aid"], let aid = Int(aidText), aid > 0 else { continue }
            let title = firstNonEmpty([
                item.value("Title") ?? "",
                item.elementValue("Title") ?? "",
                item.elementValue("title") ?? "",
            ])
            guard !title.isEmpty else { continue }
            let author = firstNonEmpty([item.value("Author") ?? "", item.elementValue("Author") ?? ""])
            results.append(NovelSummary(
                id: aid,
                title: title,
                author: author.isEmpty ? nil : author,
                coverURL: CoverURL.image(for: aid)
            ))
        }
        return results.uniquedByID()
    }

    /// `action=articlelist` returns bare `<item aid='…'/>` rows without titles, so
    /// they are only usable when a title is already known elsewhere. Kept for
    /// callers that only need ids.
    public static func ids(_ xml: String) -> [Int] {
        items(xml).compactMap { item in
            item.attributes["aid"].flatMap { Int($0) }
        }
    }

    /// `action=book&do=meta`.
    public static func detail(_ xml: String, aid: Int) -> NovelDetail {
        let roots = parse(xml)
        var fields: [String: String] = [:]
        var sid = ""
        func walk(_ records: [Record]) {
            for record in records {
                if record.name == "data", let key = record.attributes["name"] {
                    let value = firstNonEmpty([
                        record.attributes["value"] ?? "",
                        record.attributes["__text"] ?? "",
                    ])
                    if !value.isEmpty { fields[key] = value }
                    if key == "PressId", let id = record.attributes["sid"] { sid = id }
                }
                walk(record.children)
            }
        }
        walk(roots)

        let title = fields["Title"] ?? ""
        return NovelDetail(
            id: aid,
            title: title,
            author: fields["Author"] ?? "",
            category: fields["PressId"] ?? "",
            status: fields["BookStatus"] ?? "",
            wordCount: fields["BookLength"] ?? "",
            updatedAt: fields["LastUpdate"] ?? "",
            intro: fields["Intro"] ?? "",
            coverURL: CoverURL.image(for: aid)
        )
    }

    /// `action=book&do=intro` returns plain text.
    public static func intro(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Catalogue

    /// `action=book&do=list` → `<package><volume vid>…<chapter cid>…`.
    public static func volumes(_ xml: String) -> [Volume] {
        let roots = parse(xml)
        var volumes: [Volume] = []

        func chapters(in record: Record) -> [ChapterLink] {
            var result: [ChapterLink] = []
            for child in record.children where child.name == "chapter" {
                guard let cidText = child.attributes["cid"], let cid = Int(cidText), cid > 0 else { continue }
                let title = firstNonEmpty([child.attributes["__text"] ?? ""])
                result.append(ChapterLink(id: cid, title: title))
            }
            return result
        }

        for record in roots where record.name == "package" {
            for volume in record.children where volume.name == "volume" {
                let chapters = chapters(in: volume)
                guard !chapters.isEmpty else { continue }
                let title = firstNonEmpty([volume.attributes["__text"] ?? ""])
                volumes.append(Volume(
                    id: "\(volumes.count)",
                    title: title.isEmpty ? "第 \(volumes.count + 1) 卷" : title,
                    chapters: chapters
                ))
            }
        }

        // Tolerate a flat chapter list with no volume wrapper.
        if volumes.isEmpty, let package = roots.first(where: { $0.name == "package" }) {
            let flat = chapters(in: package)
            if !flat.isEmpty {
                volumes.append(Volume(id: "0", title: "正文", chapters: flat))
            }
        }
        return volumes
    }

    // MARK: - Chapters

    /// `action=book&do=text` answers with plain text, blank-line separated.
    ///
    /// Illustrations arrive inline as `<!--image-->https://…jpg<!--image-->`.
    /// Without handling that marker the URLs were simply printed into the body,
    /// which is why illustration chapters used to show a wall of links.
    public static func chapter(_ body: String, aid: Int, cid: Int) -> ChapterContent {
        let text = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var blocks: [ChapterContent.Block] = []
        var title = ""

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let (lineTitle, lineBlocks) = splitImages(in: rawLine)
            if title.isEmpty, blocks.isEmpty, lineBlocks.allSatisfy({ if case .paragraph = $0 { return true }; return false }) {
                let plain = line.replacingOccurrences(of: "\u{3000}", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !plain.isEmpty, plain.count <= 40 {
                    title = plain
                    continue
                }
            }
            if !lineTitle.isEmpty, title.isEmpty, blocks.isEmpty {
                title = lineTitle
            }
            blocks.append(contentsOf: lineBlocks)
        }

        return ChapterContent(novelID: aid, chapterID: cid, title: title, blocks: blocks)
    }

    /// Splits one line into its text runs and illustration URLs.
    static func splitImages(in line: String) -> (title: String, blocks: [ChapterContent.Block]) {
        var blocks: [ChapterContent.Block] = []
        guard line.contains("<!--image-->") else {
            let plain = line.trimmingCharacters(in: .whitespaces)
            return ("", plain.isEmpty ? [] : [.paragraph(plain)])
        }

        var remainder = line
        while let open = remainder.range(of: "<!--image-->") {
            let before = String(remainder[remainder.startIndex..<open.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !before.isEmpty {
                blocks.append(.paragraph(before))
            }
            let afterOpen = remainder[open.upperBound...]
            if let close = afterOpen.range(of: "<!--image-->") {
                let raw = String(afterOpen[afterOpen.startIndex..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = imageURL(from: raw) {
                    blocks.append(.image(url))
                } else if !raw.isEmpty {
                    blocks.append(.paragraph(raw))
                }
                remainder = String(afterOpen[close.upperBound...])
            } else {
                let raw = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = imageURL(from: raw) {
                    blocks.append(.image(url))
                } else if !raw.isEmpty {
                    blocks.append(.paragraph(raw))
                }
                remainder = ""
                break
            }
        }
        let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            blocks.append(.paragraph(tail))
        }
        return ("", blocks)
    }

    /// Only absolute http(s) URLs become image blocks. `CoverURL.normalize`
    /// accepts any string, which would turn a broken marker into an empty image.
    static func imageURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("//") else {
            return nil
        }
        return CoverURL.normalize(trimmed)
    }

    // MARK: - Account

    /// `action=login` and the bookcase writes answer with a bare integer.
    public static func resultCode(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func userName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if Int(trimmed) != nil { return nil }
        if trimmed.hasPrefix("<") {
            for record in parse(trimmed) {
                let name = firstNonEmpty([
                    record.value("UserName") ?? "",
                    record.value("username") ?? "",
                    record.value("Name") ?? "",
                ])
                if !name.isEmpty { return name }
            }
            return nil
        }
        return trimmed
    }

    public static func message(for code: Int) -> String {
        switch code {
        case 1: return "操作成功"
        case 2: return "用户名不存在"
        case 3: return "密码错误"
        case 4: return "尚未登录"
        case 5: return "这本书已经在书架里了"
        case 6: return "书架已满"
        case 7: return "这本书不在书架里"
        case 8: return "主题不存在"
        case 9: return "签到失败"
        case 10: return "推荐失败"
        case 11: return "发帖失败"
        case 22: return "引用页不存在"
        default: return "操作失败（\(code)）"
        }
    }

    /// `action=xml&item=sort` → `<item sort="1">电击文库</item>`.
    public static func sorts(_ xml: String) -> [LibraryCategory] {
        var results: [LibraryCategory] = []
        func walk(_ records: [Record]) {
            for record in records {
                if record.name == "item",
                   let sortText = record.attributes["sort"],
                   let id = Int(sortText) {
                    let name = firstNonEmpty([record.attributes["__text"] ?? ""])
                    if !name.isEmpty { results.append(LibraryCategory(id: id, name: name)) }
                }
                walk(record.children)
            }
        }
        walk(parse(xml))
        return results
    }

    // MARK: - Helpers

    private static func firstNonEmpty(_ values: [String]) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// The library taxonomy (`action=xml&item=sort`).
    ///
    /// ```xml
    /// <item sort="1">电击文库</item>
    /// ```
    ///
    /// A leading "全部轻小说" entry is prepended because every listing screen offers it
    /// and the relay does not name it.
    public static func categories(_ text: String) -> [LibraryCategory]? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<item\s+sort="(\d+)"[^>]*>([\s\S]*?)</item>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var items: [LibraryCategory] = []
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 2,
                  let idRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let id = Int(text[idRange]) else { continue }
            let name = text[nameRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            items.append(LibraryCategory(id: id, name: name))
        }
        guard !items.isEmpty else { return nil }
        return [LibraryCategory(id: 0, name: "全部轻小说")] + items
    }

    // MARK: - Bookshelf

    /// One entry of the relay's bookshelf listing.
    public struct RelayShelfEntry: Hashable, Sendable {
        public var aid: Int
        /// `YYYY-MM-DD`, present on the fuller listing only.
        public var date: String?
        public var name: String?
        public var latestChapterCID: Int?
        public var latestChapterName: String?

        public init(
            aid: Int,
            date: String? = nil,
            name: String? = nil,
            latestChapterCID: Int? = nil,
            latestChapterName: String? = nil
        ) {
            self.aid = aid
            self.date = date
            self.name = name
            self.latestChapterCID = latestChapterCID
            self.latestChapterName = latestChapterName
        }
    }

    /// Reads the relay's bookshelf listing.
    ///
    /// Two shapes exist and both are real:
    ///
    /// ```xml
    /// <metadata><book aid="3988" /></metadata>                       <!-- do=list -->
    /// <metadata><book aid="3988" date="2026-08-23">…</book></metadata> <!-- action=bookcase -->
    /// ```
    ///
    /// Attributes are read by name, never by position: a positional read of `aid` would
    /// swallow the following `date` and silently produce zero entries. An entry whose
    /// id is not a number is skipped rather than failing the whole listing — one broken
    /// record must not cost the reader the rest of the shelf.
    public static func bookcaseEntries(_ text: String) -> [RelayShelfEntry] {
        var entries: [RelayShelfEntry] = []
        for block in bookBlocks(text) {
            guard let aidText = attribute("aid", in: block),
                  let aid = Int(aidText) else { continue }
            entries.append(RelayShelfEntry(
                aid: aid,
                date: attribute("date", in: block),
                name: element("name", in: block),
                latestChapterCID: attribute("cid", in: block).flatMap(Int.init),
                latestChapterName: element("chapter", in: block)
                    ?? element("section", in: block)
            ))
        }
        return entries
    }

    /// Splits the listing into `<book …>…</book>` blocks, tolerating self-closing tags.
    private static func bookBlocks(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<book\b[^>]*/>|<book\b[^>]*>[\s\S]*?</book>"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attribute(_ name: String, in block: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        guard let match = regex.firstMatch(in: block, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: block) else { return nil }
        return String(block[found])
    }

    private static func element(_ tag: String, in block: String) -> String? {
        let pattern = "<" + NSRegularExpression.escapedPattern(for: tag)
            + #"\b[^>]*>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?</"#
            + NSRegularExpression.escapedPattern(for: tag) + ">"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        guard let match = regex.firstMatch(in: block, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: block) else { return nil }
        let value = String(block[found]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
