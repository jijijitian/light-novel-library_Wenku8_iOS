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
        // The page nominates ten books per section, but some entries link to "#"
        // because the title was removed; only real book links survive.
        XCTAssertEqual(year.sections[0].novels.count, 8)
        XCTAssertEqual(year.sections[0].novels.first?.id, 3988)
        XCTAssertEqual(year.sections[0].novels.first?.title, "玩乐关系")
        XCTAssertTrue(year.sections.allSatisfy { $0.novels.allSatisfy { $0.id > 0 } })
        XCTAssertEqual(Set(year.allBooks.map(\.id)).count, year.allBooks.count)
    }

    func testGBKEncodedYearPage() throws {
        let year = SugoiParser.parse(try fixture("sugoi2025.html"), year: 2025)
        XCTAssertFalse(year.allBooks.isEmpty)
        XCTAssertEqual(year.sections.first?.novels.first?.id, 3057)
        XCTAssertEqual(year.sections.first?.novels.first?.title, "败北女角太多了！(败犬女主太多了！)")
    }

    func testYearListCoversArchivedYears() {
        XCTAssertEqual(SugoiParser.availableYears.first, 2026)
        XCTAssertEqual(SugoiParser.availableYears.last, 2006)
        XCTAssertEqual(SugoiParser.availableYears.count, 21)
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
