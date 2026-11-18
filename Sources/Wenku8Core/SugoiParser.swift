import Foundation

/// Parser for the "这本轻小说真厉害！" yearly ranking pages, which the site still
/// serves as static pages (`/zt/sugoi/<year>.php`) and therefore work without
/// a session.
public enum SugoiParser {
    public struct Year: Identifiable, Hashable, Sendable {
        public var id: Int
        public var year: Int
        public var sections: [Section]

            /// Every real book, in order. Entries without a library page are left out: this
        /// list feeds navigation, which needs a book id.
        public var allBooks: [NovelSummary] { sections.flatMap(\.novels).filter { $0.id > 0 } }
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public var id: String
        public var caption: String
        public var novels: [NovelSummary]
    }

    /// Years the site publishes a yearly board for.
    ///
    /// The site keeps a page per year back to 2005. A year with no data answers with an
    /// empty page rather than a 404, so the range is listed here and the fetch reports
    /// "no data" for a year that turns out to be empty, instead of the year silently
    /// being missing from the picker.
    public static let availableYears: [Int] = Array(stride(from: 2026, through: 2005, by: -1))

    public static func parse(_ html: String, year: Int) -> Year {
        var sections: [Section] = []
        let captionRegex = try? NSRegularExpression(
            pattern: #"<caption>([^<]+)</caption>"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = captionRegex?.matches(in: html, range: range) ?? []

        for (index, match) in matches.enumerated() {
            guard let captionRange = Range(match.range(at: 1), in: html) else { continue }
            let caption = Markup.normalize(
                Markup.decodeEntities(String(html[captionRange]))
                    .replacingOccurrences(of: "这本轻小说真厉害！", with: "")
            )
            let start = Range(match.range, in: html)?.upperBound ?? html.endIndex
            let end: String.Index
            if index + 1 < matches.count, let next = Range(matches[index + 1].range, in: html) {
                end = next.lowerBound
            } else {
                end = html.endIndex
            }
            let body = String(html[start..<end])
            let novels = books(in: body)
            guard !novels.isEmpty else { continue }
            sections.append(Section(id: "\(year)-\(index)", caption: caption, novels: novels))
        }

        return Year(id: year, year: year, sections: sections)
    }

    /// The book id in a `/book/123.htm` href, or nil when the link is not a book.
    private static func bookID(in href: String) -> Int? {
        guard let range = href.range(of: #"book/(\d+)\.htm"#, options: .regularExpression) else {
            return nil
        }
        let digits = href[range].filter(\.isNumber)
        return Int(digits)
    }

    /// A stable negative id for a ranking entry the library has no page for.
    ///
    /// Derived from the title rather than from `hashValue`, which differs between launches
    /// and would break SwiftUI's identity for the row on every run.
    private static func placeholderID(for title: String) -> Int? {
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        guard sum > 0 else { return nil }
        return -(sum % 1_000_000 + 1)
    }

    static func books(in html: String) -> [NovelSummary] {
        // Modern pages lay each ranking position out in a fixed-width cell, so counting
        // cells gives the true number of positions. An entry the library does not stock is
        // linked to "#"; some of those still carry a title, and some carry nothing at all.
        // All of them are kept: dropping the empty ones made a TOP10 render as eight.
        if let cells = try? NSRegularExpression(
            pattern: #"<div[^>]*WIDTH:\s*19%[^>]*>(.*?)</div>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = cells.matches(in: html, range: range)
            if !matches.isEmpty {
                return books(inCells: matches, html: html)
            }
        }

        // Older pages (2006-2011) use uppercase tags with no title attribute and no cell
        // layout, so the anchors are all there is to go on.
        var novels: [NovelSummary] = []
        var seen = Set<Int>()
        if let plain = try? NSRegularExpression(
            pattern: #"<a\s+href="(?:[^"]*/)?book/(\d+)\.htm"[^>]*>([^<]{1,200})</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in plain.matches(in: html, range: range) {
                guard let idRange = Range(match.range(at: 1), in: html),
                      let textRange = Range(match.range(at: 2), in: html),
                      let id = Int(html[idRange]),
                      seen.insert(id).inserted else { continue }
                let title = Markup.normalize(Markup.decodeEntities(String(html[textRange])))
                guard !title.isEmpty else { continue }
                novels.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
            }
        }
        return novels
    }

    /// Reads one ranking position per cell, preserving the order and the count.
    private static func books(
        inCells matches: [NSTextCheckingResult],
        html: String
    ) -> [NovelSummary] {
        var novels: [NovelSummary] = []
        var seen = Set<Int>()
        // Stable per page, so the ids of unnamed positions do not change between launches.
        let pageTag = html.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 1000

        for (index, match) in matches.enumerated() {
            guard let cellRange = Range(match.range(at: 1), in: html) else { continue }
            let cell = String(html[cellRange])
            let href = firstGroup(#"href="([^"]*)""#, in: cell)
            let titleAttribute = firstGroup(#"title="([^"]*)""#, in: cell)
            let anchorText = firstGroup(#">([^<]{1,200})</a>"#, in: cell)

            let raw = [titleAttribute, anchorText]
                .compactMap { $0 }
                .first { !Markup.normalize(Markup.decodeEntities($0)).isEmpty } ?? ""
            let title = Markup.normalize(Markup.decodeEntities(raw))

            if let href, let id = bookID(in: href) {
                guard seen.insert(id).inserted else { continue }
                novels.append(NovelSummary(
                    id: id,
                    title: title,
                    coverURL: CoverURL.image(for: id)
                ))
            } else if !title.isEmpty, let placeholder = placeholderID(for: title) {
                guard seen.insert(placeholder).inserted else { continue }
                novels.append(NovelSummary(id: placeholder, title: title, coverURL: nil))
            } else {
                // A position with no title, no text and no cover: the site itself has
                // nothing to show there. The slot is still rendered so the ranking reads
                // with the right number of places.
                let placeholder = -(pageTag * 100 + index + 1)
                guard seen.insert(placeholder).inserted else { continue }
                novels.append(NovelSummary(id: placeholder, title: "未收录作品", coverURL: nil))
            }
        }
        return novels
    }

    /// The first capture group of `pattern` in `text`, decoded.
    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let groupRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[groupRange])
    }
}
