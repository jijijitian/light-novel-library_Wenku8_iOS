import Foundation

/// Parses the XML documents the relay returns.
///
/// The relay mirrors the desktop client's wire format, which is the same shape as
/// the samples kept in the Android project's `eclipse-android-old` interface
/// comments: a root `metadata`/`package` element wrapping `item` rows, each row
/// carrying the fields as child elements.
public enum RelayParser {
    /// Parses a `<metadata>` / `item` list (book info, novel lists, bookcase).
    public static func items(_ xml: String) -> [NovelSummary] {
        let root = Markup.parse(xml)
        var results: [NovelSummary] = []
        for item in root.elements(named: "item") {
            guard let summary = summary(from: item) else { continue }
            results.append(summary)
        }
        return results
    }

    private static func summary(from item: Element) -> NovelSummary? {
        let aid = intValue(item, keys: ["aid", "id", "articleid"])
        guard let aid, aid > 0 else { return nil }
        let title = stringValue(item, keys: ["title", "articlename", "name"])
        guard !title.isEmpty else { return nil }
        let author = stringValue(item, keys: ["author", "authorname"])
        return NovelSummary(
            id: aid,
            title: title,
            author: author.isEmpty ? nil : author,
            coverURL: CoverURL.image(for: aid)
        )
    }

    /// A `<book>` block with full metadata, as returned by `book&do=meta`.
    public static func detail(_ xml: String, aid: Int) -> NovelDetail {
        let root = Markup.parse(xml)
        let book = root.firstElement(named: "book") ?? root
        let items = root.elements(named: "item")
        let meta = items.first { item in
            (intValue(item, keys: ["aid", "id"]) ?? 0) == aid
        }

        let title = firstNonEmpty([
            stringValue(book, keys: ["title", "articlename", "name"]),
            meta.map { stringValue($0, keys: ["title", "articlename", "name"]) } ?? "",
        ])
        let author = firstNonEmpty([
            stringValue(book, keys: ["author", "authorname"]),
            meta.map { stringValue($0, keys: ["author", "authorname"]) } ?? "",
        ])
        let intro = firstNonEmpty([
            stringValue(book, keys: ["intro", "introduction", "content", "description"]),
            meta.map { stringValue($0, keys: ["intro", "introduction", "content", "description"]) } ?? "",
        ])

        let bookID = intValue(book, keys: ["aid", "id"]) ?? aid
        return NovelDetail(
            id: bookID > 0 ? bookID : aid,
            title: title,
            author: author,
            category: stringValue(book, keys: ["sort", "class", "sortname", "category"]),
            status: stringValue(book, keys: ["full", "state", "status"]),
            wordCount: stringValue(book, keys: ["size", "wordcount", "length"]),
            updatedAt: stringValue(book, keys: ["lastupdate", "update", "lastupdateTime"]),
            intro: intro,
            coverURL: CoverURL.image(for: bookID > 0 ? bookID : aid)
        )
    }

    /// The chapter list is nested as `package > volume > chapter` (older builds
    /// emit `item` instead of `volume`). Chapter IDs sit on the `<chapter>` node.
    public static func volumes(_ xml: String) -> [Volume] {
        let root = Markup.parse(xml)
        var volumes: [Volume] = []

        for container in root.elements(named: "package") {
            for (volumeIndex, volumeElement) in chapters(from: container).enumerated() {
                let title = firstNonEmpty([
                    volumeElement.element.attribute("name") ?? "",
                    volumeElement.element.attribute("title") ?? "",
                    stringValue(volumeElement.element, keys: ["name", "title", "volumename"]),
                ])
                let rows: [Element] = volumeElement.chapters
                guard !rows.isEmpty else { continue }
                var chapters: [ChapterLink] = []
                for row in rows {
                    guard let cid = intValue(row, keys: ["cid", "id", "chapterid"]), cid > 0 else { continue }
                    let name = firstNonEmpty([
                        stringValue(row, keys: ["title", "chaptername", "name"]),
                        row.attribute("title") ?? "",
                        row.attribute("name") ?? "",
                    ])
                    chapters.append(ChapterLink(id: cid, title: name))
                }
                guard !chapters.isEmpty else { continue }
                let volumeTitle = title.isEmpty ? "第 \(volumeIndex + 1) 卷" : title
                volumes.append(Volume(id: "\(volumes.count)", title: volumeTitle, chapters: chapters))
            }
        }

        if volumes.isEmpty {
            // Some builds answer with a flat `<chapter>` list and no volume wrapper.
            var chapters: [ChapterLink] = []
            for row in root.elements(named: "chapter") {
                guard let cid = intValue(row, keys: ["cid", "id", "chapterid"]), cid > 0 else { continue }
                let name = firstNonEmpty([
                    stringValue(row, keys: ["title", "chaptername", "name"]),
                ])
                chapters.append(ChapterLink(id: cid, title: name))
            }
            if !chapters.isEmpty {
                volumes.append(Volume(id: "0", title: "正文", chapters: chapters))
            }
        }
        return volumes
    }

    private struct VolumeChunk {
        var element: Element
        var chapters: [Element]
    }

    /// Walks one `<package>` and yields its volumes. A volume is either an
    /// explicit `volume`/`item` child that itself contains `chapter` rows, or —
    /// when chapters hang directly off the package — a single implicit volume.
    private static func chapters(from container: Element) -> [VolumeChunk] {
        var chunks: [VolumeChunk] = []
        var loose: [Element] = []
        for child in container.childElements {
            switch child.name {
            case "volume", "item":
                let rows = chapterRows(in: child)
                if !rows.isEmpty {
                    chunks.append(VolumeChunk(element: child, chapters: rows))
                }
            case "chapter":
                loose.append(child)
            default:
                continue
            }
        }
        if !loose.isEmpty {
            chunks.append(VolumeChunk(element: Element(name: "volume"), chapters: loose))
        }
        return chunks
    }

    private static func chapterRows(in container: Element) -> [Element] {
        let direct = container.childElements.filter { $0.name == "chapter" || $0.name == "item" }
        if !direct.isEmpty { return direct }
        return container.elements(named: "chapter")
    }

    /// Parses a `book&do=text` chapter body.
    ///
    /// The relay wraps the body in `<content>` with `<p>` per paragraph and may
    /// inline `<img>` illustrations, which are mapped to `.image` blocks.
    public static func chapter(_ xml: String, aid: Int, cid: Int) -> ChapterContent {
        let root = Markup.parse(xml)
        let container = root.firstElement(named: "content") ?? root
        let title = firstNonEmpty([
            stringValue(container, keys: ["title", "chaptername"]),
            stringValue(root, keys: ["title", "chaptername"]),
        ])

        var blocks: [ChapterContent.Block] = []
        for paragraph in container.elements(named: "p") {
            let text = normalize(paragraph.textContent)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
        }
        for image in container.elements(named: "img") {
            if let source = image.attribute("src") ?? image.attribute("data-src"),
               let url = CoverURL.normalize(source) {
                blocks.append(.image(url))
            }
        }
        if blocks.isEmpty {
            let text = normalize(container.textContent)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
        }
        return ChapterContent(novelID: aid, chapterID: cid, title: title, blocks: blocks)
    }

    /// Parses `action=search` results, which use the same `item` rows.
    public static func search(_ xml: String) -> [NovelSummary] {
        items(xml)
    }

    /// Parses the plain integer reply codes (`1` success … `22` …).
    public static func resultCode(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    /// Parses `action=userinfo`, which answers either plain text or an `<item>`.
    public static func userName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            let root = Markup.parse(trimmed)
            let keys = ["username", "name", "user", "nickname"]
            // Accept both a flat `<username>` child and the nested
            // `<metadata><item><username>` shape the relay uses elsewhere.
            let candidates = [root] + root.descendants()
            for element in candidates {
                let name = stringValue(element, keys: keys)
                if !name.isEmpty, Int(name) == nil { return name }
            }
            return nil
        }
        if Int(trimmed) != nil { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Maps a bookcase/login reply code to a user-facing message.
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

    // MARK: - Helpers

    private static func stringValue(_ element: Element, keys: [String]) -> String {
        for key in keys {
            for child in element.childElements where child.name == key {
                let text = normalize(child.textContent)
                if !text.isEmpty { return text }
            }
            if let attribute = element.attribute(key) {
                let text = normalize(attribute)
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    private static func intValue(_ element: Element, keys: [String]) -> Int? {
        let raw = stringValue(element, keys: keys)
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func firstNonEmpty(_ values: [String]) -> String {
        for value in values {
            let trimmed = normalize(value)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
