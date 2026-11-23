import Foundation

/// The site's downloadable text pack, split back into volumes and chapters.
///
/// A restricted book — one the site stopped serving "at rights holders' request" — still has
/// its text available as a per-volume download:
///
///     https://dl.wenku8.com/packtxt.php?aid=1614&vid=54755&type=gbk
///
/// That file is one volume of plain text with no markup, and every chapter heading inside it
/// repeats the volume name as a prefix:
///
/// ```
///   第一卷 第一章 学姐是兔女郎
///       ——呐，来接吻吧。
/// ```
///
/// So the pack alone is enough to rebuild the catalogue: the heading lines give the chapter
/// titles in reading order, and stripping the repeated prefix leaves the chapter name. Nothing
/// else marks a chapter boundary, which is why the prefix has to be matched exactly — a
/// paragraph that merely begins with 第…章 must not be mistaken for a heading.
public enum TextPackParser {
    /// One volume of a downloaded pack, split at its headings.
    public struct ParsedVolume: Sendable {
        /// The volume name the pack repeats on each heading, e.g. `第一卷`.
        public var name: String
        /// Chapters in file order, each with the body that followed its heading.
        public var chapters: [ParsedChapter]

        public init(name: String, chapters: [ParsedChapter]) {
            self.name = name
            self.chapters = chapters
        }
    }

    public struct ParsedChapter: Sendable {
        /// The heading with the volume prefix removed, e.g. `第一章 学姐是兔女郎`.
        public var title: String
        /// Body paragraphs, in order, already trimmed. Empty for an illustration-only chapter.
        public var paragraphs: [String]

        public init(title: String, paragraphs: [String]) {
            self.title = title
            self.paragraphs = paragraphs
        }
    }

    /// The banner the pack opens with, which is not content.
    private static let bannerPrefix = "★☆★☆★☆轻小说文库"

    /// Matches the chapter marker inside a heading: 第一章 / 第12章 / 第二百章.
    private static let chapterMarker = #"第[零〇一二三四五六七八九十百千0-9]+章"#

    /// Splits one downloaded volume.
    ///
    /// - Parameter text: the pack decoded with `TextDecoding.decode`. The endpoint labels its
    ///   response `charset=utf-8` while writing GBK, so the bytes must not be trusted to be
    ///   UTF-8.
    public static func parse(_ text: String) -> ParsedVolume? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // The volume's own name is whatever a heading puts before its chapter marker. Reading
        // it from the first heading is enough: every heading in a file repeats the same name.
        guard let firstIndex = lines.firstIndex(where: { headingName($0) != nil }),
              let volumeName = headingName(lines[firstIndex]) else {
            return nil
        }

        var chapters: [ParsedChapter] = []
        var currentTitle: String?
        var body: [String] = []

        func flush() {
            if let title = currentTitle {
                chapters.append(ParsedChapter(title: title, paragraphs: body))
            }
            body = []
        }

        for line in lines[firstIndex...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(bannerPrefix) { continue }

            // Only a line that starts with this volume's name and then a chapter marker is a
            // heading. Prose that opens with 第…章 does not carry the volume prefix.
            if let (name, title) = splitHeading(trimmed), name == volumeName {
                flush()
                currentTitle = title
                continue
            }
            if currentTitle == nil {
                // The printer's notes before the first heading belong to no chapter.
                continue
            }
            body.append(trimmed)
        }
        flush()

        guard !chapters.isEmpty else { return nil }
        return ParsedVolume(name: volumeName, chapters: chapters)
    }

    /// The volume name a heading repeats, or nil when the line is not a heading.
    static func headingName(_ line: String) -> String? {
        splitHeading(line.trimmingCharacters(in: .whitespaces))?.0
    }

    /// `第一卷 第一章 学姐是兔女郎` → (`第一卷`, `第一章 学姐是兔女郎`).
    ///
    /// A volume may title itself (`第二卷 青春猪头少年不会梦到小恶魔学妹`), so the split happens
    /// at the chapter marker rather than at the first 卷.
    private static func splitHeading(_ line: String) -> (String, String)? {
        guard line.count <= 80, line.hasPrefix("第") else { return nil }
        // A heading is one line of a title; prose runs far longer and ends in a full stop.
        // Question and exclamation marks are legitimate in titles (「明天的事明天再说？」),
        // so only the full stop is disqualifying.
        guard !line.hasSuffix("。"), !line.contains("，") else { return nil }

        if let range = line.range(of: chapterMarker, options: .regularExpression) {
            let name = String(line[line.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.contains("卷") else { return nil }
            return (name, String(line[range.lowerBound...]))
        }

        // 终章 / 后记 / 插图 carry no numbered marker; they follow the volume token directly.
        guard let volumeEnd = line.firstIndex(of: "卷") else { return nil }
        let token = String(line[line.startIndex...volumeEnd])
        guard token.count >= 3 else { return nil }
        guard token.dropFirst().dropLast().allSatisfy(isNumberCharacter) else { return nil }
        let rest = String(line[line.index(after: volumeEnd)...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let allowed = ["终章", "插图", "后记", "序", "尾声", "番外"]
        guard rest.hasPrefix("第") || allowed.contains(where: { rest.hasPrefix($0) }) else {
            return nil
        }
        return (token, rest)
    }

    /// A chapter id for a chapter that exists only inside a downloaded pack.
    ///
    /// The site assigns real ids, but a delisted book's chapters cannot be fetched by id, so
    /// the id only has to be stable across launches and unique within the book. `vid` and the
    /// chapter's position in the file give that.
    public static func stableChapterID(vid: Int, index: Int) -> Int {
        // Negative so it can never collide with a real chapter id, which is positive.
        -(vid * 1000 + index)
    }

    private static func isNumberCharacter(_ character: Character) -> Bool {
        "零〇一二三四五六七八九十百千".contains(character)
            || (character >= "0" && character <= "9")
    }
}
