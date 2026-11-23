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
        let raw = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // The pack's shape, as measured across books: a heading sits on its own line, is
        // preceded by a blank line, and is immediately followed by its first paragraph with
        // no blank line between them. Every later paragraph is separated by a blank line. So
        // the headings are exactly the lines that follow a blank line and have a non-blank
        // line after them.
        //
        // The one exception is an illustration chapter, which has no paragraph of its own: it
        // is followed by two blank lines when another chapter follows, and by the volume's
        // separator at the end.
        var chapters: [ParsedChapter] = []
        var currentTitle: String?
        var body: [String] = []

        func flush() {
            if let title = currentTitle {
                chapters.append(ParsedChapter(title: title, paragraphs: body))
            }
            body = []
        }

        let count = raw.count
        // The first line is a candidate too: a pack always opens with a banner line, but a
        // caller may hand over text that starts straight at the first heading.
        for index in 0..<count {
            if index == 0 {
                let line = raw[0].trimmingCharacters(in: .whitespaces)
                let next = count > 1 ? raw[1].trimmingCharacters(in: .whitespaces) : ""
                if !line.isEmpty, !line.hasPrefix(bannerPrefix), isHeading(line, next: next) {
                    currentTitle = stripVolumePrefix(line, volumeName: volumeName ?? inferredVolumeName(raw))
                }
                continue
            }
            let line = raw[index].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(bannerPrefix) else { continue }
            let previous = raw[index - 1].trimmingCharacters(in: .whitespaces)
            let next = index + 1 < count ? raw[index + 1].trimmingCharacters(in: .whitespaces) : ""

            if previous.isEmpty, isHeading(line, next: next) {
                flush()
                currentTitle = stripVolumePrefix(line, volumeName: volumeName ?? inferredVolumeName(raw))
                continue
            }
            guard currentTitle != nil else { continue }
            // The trailing site blurb is not content.
            if line.hasPrefix("更多精彩热门") || line.hasPrefix("◆◇◆") { continue }
            body.append(line)
        }
        flush()

        guard !chapters.isEmpty else { return nil }
        return ParsedVolume(name: volumeName ?? inferredVolumeName(raw), chapters: chapters)
    }

    /// The volume name the pack repeats before each heading, e.g. `第四卷`.
    ///
    /// Taken from the first heading: every heading carries the same prefix, and a volume that
    /// titles itself puts that title there too.
    public static func inferredVolumeName(_ lines: [String]) -> String {
        let count = lines.count
        for index in 1..<count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(bannerPrefix) else { continue }
            let previous = lines[index - 1].trimmingCharacters(in: .whitespaces)
            let next = index + 1 < count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            guard previous.isEmpty, isHeading(line, next: next) else { continue }
            if let space = line.firstIndex(of: " ") {
                return String(line[line.startIndex..<space])
            }
            return line
        }
        return ""
    }

    /// Removes the repeated `第四卷 ` before a chapter name.
    static func stripVolumePrefix(_ line: String, volumeName: String) -> String {
        guard !volumeName.isEmpty, line.hasPrefix(volumeName) else { return line }
        let rest = String(line.dropFirst(volumeName.count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? line : rest
    }

    /// Whether a line that follows a blank line is a chapter heading.
    ///
    /// - Parameter next: the line after it; a heading's own first paragraph follows directly.
    static func isHeading(_ line: String, next: String) -> Bool {
        if line.hasPrefix("◆◇") || line.hasPrefix("更多精彩热门") { return false }
        // An illustration chapter has no text of its own.
        if line.hasSuffix("插图") || line.hasSuffix("彩页") { return true }
        guard !next.isEmpty else { return false }
        // A paragraph never starts right after another line without a blank between, so a
        // non-blank follower is what distinguishes a heading from ordinary prose.
        if next.hasPrefix("◆") || next.hasPrefix("更多精彩热门") { return false }
        // Titles are short; prose that happens to follow a blank line runs long.
        return line.count <= 60
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

    /// Splits a single-chapter response into the one chapter it targets.
    ///
    /// `packtxt.php?vid=<cid>` answers with up to a whole volume: for one book it is that
    /// chapter alone, for another it starts at the chapter and continues to the end of the
    /// volume. The response is therefore cut at the headings, and the first one is the
    /// chapter asked for.
    public static func singleChapter(_ text: String) -> ParsedChapter? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { isLooseHeading($0) }) else { return nil }
        let title = lines[start]
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line.isEmpty { continue }
            if line.hasPrefix(bannerPrefix) { continue }
            // The next heading ends this chapter.
            if isLooseHeading(line) { break }
            body.append(line)
        }
        return ParsedChapter(title: title, paragraphs: body)
    }

    /// A heading in a single-chapter response, where no volume prefix repeats.
    private static func isLooseHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 48, !line.hasSuffix("。") else { return false }
        guard !line.hasPrefix("台版"), !line.hasPrefix("扫图"), !line.hasPrefix("录入"),
              !line.hasPrefix("修图"), !line.hasPrefix("翻译") else { return false }
        let markers = ["第", "序", "终章", "后记", "插图", "尾声", "番外"]
        guard markers.contains(where: { line.hasPrefix($0) }) else { return false }
        // 「第X章」 must be a heading, not prose mentioning one.
        if line.hasPrefix("第") {
            return line.range(of: chapterMarker, options: .regularExpression) != nil
                || line.range(of: #"^第[零〇一二三四五六七八九十百千0-9]+卷"#, options: .regularExpression) != nil
        }
        return true
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
