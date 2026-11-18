import XCTest
@testable import Wenku8Core

final class SugoiParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "missing fixture \(name)"
        )
        return TextDecoding.decode(try Data(contentsOf: url))
    }

    func testYearPageParsesBothSections() throws {
        let year = SugoiParser.parse(try fixture("sugoi2026.html"), year: 2026)
        XCTAssertEqual(year.year, 2026)
        XCTAssertEqual(year.sections.count, 2)
        XCTAssertTrue(year.sections[0].caption.contains("文库部门"))
        XCTAssertTrue(year.sections[1].caption.contains("单行本部门"))
        // The page nominates ten books per section. An entry the library does not stock
        // links to "#"; it is still shown, because dropping it made a TOP10 render as
        // fewer rows, but it carries no book id to open.
        XCTAssertEqual(year.sections[0].novels.count, 10)
        XCTAssertEqual(year.sections[0].novels.first?.id, 3988)
        XCTAssertEqual(year.sections[0].novels.first?.title, "玩乐关系")
        // Every entry is either a real book or a titled placeholder.
        XCTAssertTrue(year.sections.allSatisfy { $0.novels.allSatisfy { $0.id != 0 } })
        XCTAssertTrue(year.sections[0].novels.contains { $0.id < 0 })
        // Only real books are offered for navigation.
        XCTAssertTrue(year.allBooks.allSatisfy { $0.id > 0 })
        XCTAssertEqual(Set(year.allBooks.map(\.id)).count, year.allBooks.count)
    }

    func testGBKEncodedYearPage() throws {
        let year = SugoiParser.parse(try fixture("sugoi2025.html"), year: 2025)
        XCTAssertFalse(year.allBooks.isEmpty)
        XCTAssertEqual(year.sections.first?.novels.first?.id, 3057)
        XCTAssertEqual(year.sections.first?.novels.first?.title, "败北女角太多了！(败犬女主太多了！)")

        // 2025 lists a full ten per section, one of which ("白色帝国") is not stocked.
        XCTAssertEqual(year.sections[0].novels.count, 10)
        let placeholder = try XCTUnwrap(year.sections[0].novels.first { $0.id < 0 })
        XCTAssertEqual(placeholder.title, "白色帝国")
        XCTAssertNil(placeholder.coverURL, "a book without a page has no cover to load")
        XCTAssertFalse(year.allBooks.contains { $0.title == "白色帝国" })
    }

    /// Pages before 2012 use uppercase tags with no title attribute, so the parser
    /// has to fall back to the visible anchor text.
    func testLegacyYearPageWithoutTitleAttribute() throws {
        let year = SugoiParser.parse(try fixture("sugoi2010.html"), year: 2010)
        XCTAssertEqual(year.sections.count, 1)
        XCTAssertEqual(year.sections[0].novels.count, 20)
        XCTAssertTrue(year.sections[0].caption.contains("2010"))
        let first = try XCTUnwrap(year.sections[0].novels.first)
        XCTAssertEqual(first.id, 4)
        XCTAssertEqual(first.title, "笨蛋，测验，招唤兽")
        XCTAssertTrue(year.allBooks.contains { $0.title == "化物语" })
    }

    func testYearListCoversArchivedYears() {
        XCTAssertEqual(SugoiParser.availableYears.first, 2026)
        XCTAssertEqual(SugoiParser.availableYears.last, 2005)
        XCTAssertEqual(SugoiParser.availableYears.count, 22)
    }

    func testEmptyPageYieldsNoSections() {
        let year = SugoiParser.parse("<html><body>no captions here</body></html>", year: 2026)
        XCTAssertTrue(year.sections.isEmpty)
        XCTAssertTrue(year.allBooks.isEmpty)
    }

    func testPlaceholderDetection() throws {
        let closed = try fixture("desktop-list.html")
        XCTAssertTrue(DesktopParser.isPlaceholder(closed))
        XCTAssertFalse(DesktopParser.isPlaceholder(try fixture("desktop-book.html")))
    }
}
