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
        var novels: [NovelSummary] = []
        var seen = Set<Int>()

        // Modern pages (2012+) carry a title attribute on the cover anchor, which is
        // the most reliable source because the visible text may be abbreviated.
        //
        // The href is matched loosely on purpose. A ranking entry can be a book the
        // library does not stock, and the site then links it to "#": a TOP10 of ten titles
        // rendered as nine because the strict pattern dropped that entry. Those keep their
        // title and are given a synthetic negative id so the row is still shown, while
        // navigation — which needs a real book id — is skipped for them.
        if let titled = try? NSRegularExpression(
            pattern: #"<a\s+href="([^"]*)"[^>]*title="([^"]*)""#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in titled.matches(in: html, range: range) {
                guard let hrefRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 2), in: html) else { continue }
                let href = String(html[hrefRange])
                let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
                guard !title.isEmpty else { continue }
                if let id = bookID(in: href) {
                    guard seen.insert(id).inserted else { continue }
                    novels.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
                } else if let placeholder = placeholderID(for: title) {
                    guard seen.insert(placeholder).inserted else { continue }
                    novels.append(NovelSummary(id: placeholder, title: title, coverURL: nil))
                }
            }
        }

        // Older pages (2006-2011) are uppercase, unquoted in places, and have no
        // title attribute, so fall back to the visible anchor text.
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
}
