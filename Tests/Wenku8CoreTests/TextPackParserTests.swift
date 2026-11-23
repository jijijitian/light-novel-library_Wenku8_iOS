import XCTest
@testable import Wenku8Core

/// Covers the pack parser that turns a delisted book's per-volume download back into
/// chapters.
///
/// The pack has no markup at all: a heading is the only thing separating one chapter from
/// the next, and it repeats the volume name before the chapter name. Getting that split
/// wrong turns the volume name into part of a title, or worse, treats a paragraph as a
/// heading.
final class TextPackParserTests: XCTestCase {
    /// A pack shaped the way the endpoint writes one: a banner, a blank line, then each
    /// heading immediately followed by its first paragraph, with blank lines between the
    /// paragraphs after that.
    private let volume = """
    ★☆★☆★☆轻小说文库(Www.WenKu8.com)☆★☆★☆★

      第一卷 第一章 学姐是兔女郎
         ——呐，来接吻吧。

        我放学回到家，看见妹妹正在客厅讲电话。

      第一卷 第二章 和好的代价
        就结论来说，惹怒麻衣的第二天。

      第一卷 插图
      
      第一卷 后记
        写完啦。
    """

    func testSplitsOnTheHeadingShape() throws {
        let parsed = try XCTUnwrap(TextPackParser.parse(volume, volumeName: "第一卷"))
        XCTAssertEqual(parsed.chapters.map(\.title), [
            "第一章 学姐是兔女郎", "第二章 和好的代价", "插图", "后记",
        ])
        XCTAssertEqual(parsed.chapters[0].paragraphs.first, "——呐，来接吻吧。")
        XCTAssertEqual(parsed.chapters[1].paragraphs, ["就结论来说，惹怒麻衣的第二天。"])
    }

    /// The volume's name is repeated before every chapter name and is not part of it.
    func testVolumePrefixIsStripped() throws {
        let parsed = try XCTUnwrap(TextPackParser.parse(volume, volumeName: "第一卷"))
        XCTAssertTrue(parsed.chapters.allSatisfy { !$0.title.hasPrefix("第一卷") })
    }

    /// A volume that titles itself keeps that title in the prefix, so the chapter name is
    /// what follows the whole thing.
    func testTitledVolumePrefix() throws {
        let text = """
          第二卷 青春猪头少年 第一章 猪头少年没有明天
            正文一。

          第二卷 青春猪头少年 第二章 明天的事明天再说？
            正文二。
        """
        let parsed = try XCTUnwrap(TextPackParser.parse(text, volumeName: "第二卷 青春猪头少年"))
        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章 猪头少年没有明天", "第二章 明天的事明天再说？"])
    }

    /// Prose separated by a blank line is not a heading: it has no paragraph directly after
    /// it, and it runs long.
    func testProseIsNotMistakenForAHeading() throws {
        let text = """
          第一卷 第一章 开始
            第一章 开始的内容写在正文里。

            他翻到第一卷 第一章 开始，又读了一遍，这一句话足够长，长到不像一个标题。

            这一段也是正文。
        """
        let parsed = try XCTUnwrap(TextPackParser.parse(text, volumeName: "第一卷"))
        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(parsed.chapters[0].title, "第一章 开始")
        XCTAssertEqual(parsed.chapters[0].paragraphs.count, 3)
    }

    /// An illustration chapter has no text; it is a heading followed by blank lines.
    func testIllustrationChapterHasNoParagraphs() throws {
        let text = """
          第一卷 第一章 开始
            正文。

          第一卷 插图
          
          第一卷 特典
            正文。
        """
        let parsed = try XCTUnwrap(TextPackParser.parse(text, volumeName: "第一卷"))
        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章 开始", "插图", "特典"])
        XCTAssertTrue(parsed.chapters[1].paragraphs.isEmpty)
    }

    func testChapterIDIsStableAndNegative() {
        let a = TextPackParser.stableChapterID(vid: 54755, index: 0)
        let b = TextPackParser.stableChapterID(vid: 54755, index: 0)
        XCTAssertEqual(a, b)
        XCTAssertLessThan(a, 0)
        XCTAssertNotEqual(a, TextPackParser.stableChapterID(vid: 54755, index: 1))
    }

    func testUnrecognisableTextReturnsNil() {
        XCTAssertNil(TextPackParser.parse(""))
        XCTAssertNil(TextPackParser.parse("只是一段普通文字，没有章节标题。"))
    }
}
