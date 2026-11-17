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
    public static func chapter(_ body: String, aid: Int, cid: Int) -> ChapterContent {
        let text = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks: [ChapterContent.Block] = []
        var title = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let cleaned = line.replacingOccurrences(of: "\u{3000}", with: "")
            if cleaned.isEmpty { continue }
            if title.isEmpty, blocks.isEmpty, cleaned.count <= 40 {
                // The relay puts the chapter title on its own first line.
                title = cleaned
                continue
            }
            blocks.append(.paragraph(line))
        }
        return ChapterContent(novelID: aid, chapterID: cid, title: title, blocks: blocks)
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
}
