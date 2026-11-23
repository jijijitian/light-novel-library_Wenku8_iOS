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
    /// - Parameters:
    ///   - text: the pack decoded with `TextDecoding.decode`. The endpoint labels its response
    ///     `charset=utf-8` while writing GBK, so the bytes must not be trusted to be UTF-8.
    ///   - volumeName: the volume's name as the site's catalogue states it. The pack repeats
    ///     this before every heading, so passing it in removes the guesswork: a volume titled
    ///     `第二卷 青春猪头少年…` puts the whole title there, and headings without a 第…章 marker
    ///     (终章 / 后记 / 插图) can then be recognised by the same prefix.
    public static func parse(_ text: String, volumeName: String? = nil) -> ParsedVolume? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // The name comes from the catalogue when the caller has it; otherwise it is whatever
        // the first heading puts before its chapter marker.
        let expected = volumeName?.trimmingCharacters(in: .whitespaces)
        guard let firstIndex = lines.firstIndex(where: { headingName($0) != nil }),
              let name = expected ?? headingName(lines[firstIndex]) else {
            return nil
        }
        let volume = name

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

            // A heading is the volume's name followed by something. Prose that mentions a
            // chapter number does not carry the volume prefix, so it stays in the body.
            if trimmed.hasPrefix(volume) {
                let rest = String(trimmed.dropFirst(volume.count))
                    .trimmingCharacters(in: .whitespaces)
                if isChapterName(rest) {
                    flush()
                    currentTitle = rest
                    continue
                }
            }
            // Without a catalogue name, fall back to the marker-based split.
            if expected == nil, let (name, title) = splitHeading(trimmed), name == volume {
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
        return ParsedVolume(name: volume, chapters: chapters)
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
        // A heading is a short title. Prose runs longer and ends in a full stop; commas and
        // question marks are legitimate inside titles (「终章 结果，第二天……」,
        // 「第二章 明天的事明天再说？」), so neither disqualifies a line.
        guard !line.hasSuffix("。") else { return nil }

        if let range = line.range(of: chapterMarker, options: .regularExpression) {
            let name = String(line[line.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.contains("卷") else { return nil }
            return (name, String(line[range.lowerBound...]))
        }

        // Headings without a numbered marker: 主要人物 / 终章 / 后记 / 插图 / 番外. They follow the
        // volume token directly, so the token is 第…卷 and the rest is the chapter name.
        guard let volumeEnd = line.firstIndex(of: "卷") else { return nil }
        let token = String(line[line.startIndex...volumeEnd])
        guard token.count >= 3 else { return nil }
        guard token.dropFirst().dropLast().allSatisfy(isNumberCharacter) else { return nil }
        let rest = String(line[line.index(after: volumeEnd)...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        // The remainder of a heading is a short name, not a sentence: a paragraph that merely
        // opens with the volume name runs long and ends in a full stop.
        guard rest.count <= 24, !rest.hasSuffix("。") else { return nil }
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

    /// True when the text after a volume name reads as a chapter name.
    ///
    /// Headings are short and never end in a full stop; a paragraph that happens to open with
    /// the volume name runs long. Commas and question marks are legitimate in titles
    /// (「终章 结果，第二天……」, 「第二章 明天的事明天再说？」), so they do not disqualify.
    private static func isChapterName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 40, !text.hasSuffix("。") else { return false }
        return true
    }

    private static func isNumberCharacter(_ character: Character) -> Bool {
        "零〇一二三四五六七八九十百千".contains(character)
            || (character >= "0" && character <= "9")
    }
}
