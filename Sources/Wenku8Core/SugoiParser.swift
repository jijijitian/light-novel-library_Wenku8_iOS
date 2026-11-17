import Foundation

/// Parser for the "这本轻小说真厉害！" yearly ranking pages, which the site still
/// serves as static pages (`/zt/sugoi/<year>.php`) and therefore work without
/// a session.
public enum SugoiParser {
    public struct Year: Identifiable, Hashable, Sendable {
        public var id: Int
        public var year: Int
        public var sections: [Section]

        public var allBooks: [NovelSummary] { sections.flatMap(\.novels) }
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public var id: String
        public var caption: String
        public var novels: [NovelSummary]
    }

    public static let availableYears: [Int] = Array(stride(from: 2026, through: 2006, by: -1))

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

    static func books(in html: String) -> [NovelSummary] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a href="(?:[^"]*/)?book/(\d+)\.htm"[^>]*title="([^"]*)""#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var novels: [NovelSummary] = []
        var seen = Set<Int>()
        for match in regex.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let id = Int(html[idRange]),
                  seen.insert(id).inserted else { continue }
            let title = Markup.normalize(Markup.decodeEntities(String(html[titleRange])))
            guard !title.isEmpty else { continue }
            novels.append(NovelSummary(id: id, title: title, coverURL: CoverURL.image(for: id)))
        }
        return novels
    }
}
