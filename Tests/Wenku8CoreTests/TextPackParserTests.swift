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
    private let volume = """
    ★☆★☆★☆轻小说文库(Www.WenKu8.com)☆★☆★☆★

      第一卷 第一章 学姐是兔女郎
          ——呐，来接吻吧。

        我放学回到家，看见妹妹正在客厅讲电话。

      第一卷 第二章 和好的代价
        就结论来说，惹怒麻衣的第二天。

      第一卷 后记
        写完啦。
    """

    func testSplitIntoChapters() throws {
        let parsed = try XCTUnwrap(TextPackParser.parse(volume))
        XCTAssertEqual(parsed.name, "第一卷")
        XCTAssertEqual(parsed.chapters.map(\.title), [
            "第一章 学姐是兔女郎", "第二章 和好的代价", "后记",
        ])
        XCTAssertEqual(parsed.chapters[0].paragraphs.first, "——呐，来接吻吧。")
        XCTAssertEqual(parsed.chapters[1].paragraphs, ["就结论来说，惹怒麻衣的第二天。"])
    }

    /// A volume may title itself, and the title belongs to the volume, not the chapter.
    func testVolumeWithItsOwnTitle() throws {
        let text = """
          第二卷 青春猪头少年不会梦到小恶魔学妹 第一章 猪头少年没有明天
            正文一。

          第二卷 青春猪头少年不会梦到小恶魔学妹 第二章 明天的事明天再说？
            正文二。
        """
        let parsed = try XCTUnwrap(TextPackParser.parse(text))
        XCTAssertEqual(parsed.name, "第二卷 青春猪头少年不会梦到小恶魔学妹")
        XCTAssertEqual(parsed.chapters.map(\.title), ["第一章 猪头少年没有明天", "第二章 明天的事明天再说？"])
    }

    /// A question mark is legitimate in a title; disqualifying it merged two chapters.
    func testQuestionMarkInTitleIsAllowed() throws {
        let parsed = try XCTUnwrap(TextPackParser.parse(volume))
        XCTAssertTrue(parsed.chapters.allSatisfy { !$0.title.isEmpty })
    }

    /// Prose that mentions a chapter number is not a heading.
    func testProseIsNotMistakenForAHeading() throws {
        let text = """
          第一卷 第一章 开始
            第一章 开始的内容写在正文里，这里只是一句话。
            他翻到第一卷 第一章 开始，又读了一遍。
        """
        let parsed = try XCTUnwrap(TextPackParser.parse(text))
        XCTAssertEqual(parsed.chapters.count, 1)
        XCTAssertEqual(parsed.chapters[0].paragraphs.count, 2)
    }

    /// A volume named by the catalogue splits exactly as the catalogue does, including the
    /// headings that carry no 第…章 marker.
    func testCatalogueNameSplitsEndingChapters() throws {
        let text = """
          第二卷 青春猪头少年 第一章 开始
            正文。

          第二卷 青春猪头少年 终章 结果，第二天……
            正文。

          第二卷 青春猪头少年 后记
            正文。

          第二卷 青春猪头少年 插图
            图片。
        """
        let parsed = try XCTUnwrap(TextPackParser.parse(text, volumeName: "第二卷 青春猪头少年"))
        XCTAssertEqual(parsed.chapters.map(\.title), [
            "第一章 开始", "终章 结果，第二天……", "后记", "插图",
        ])
    }

    /// A heading with no numbered marker at all (「主要人物」) is still a chapter.
    func testUnnumberedFirstHeading() throws {
        let text = """
          第一卷 主要人物
            人物介绍。

          第一卷 第一章 开始
            正文。
        """
        let parsed = try XCTUnwrap(TextPackParser.parse(text, volumeName: "第一卷"))
        XCTAssertEqual(parsed.chapters.map(\.title), ["主要人物", "第一章 开始"])
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
