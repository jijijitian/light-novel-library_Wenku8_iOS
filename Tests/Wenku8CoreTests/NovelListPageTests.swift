import XCTest
@testable import Wenku8Core

final class NovelListPageTests: XCTestCase {
    /// The service states the total up front; the UI needs it to show "4/426" and to
    /// know when to stop asking for more.
    func testTotalPagesIsReadFromTheListing() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <result>
        <page num='426'/>
        <item aid='1'><data name='Title' value='A'/></item>
        </result>
        """
        XCTAssertEqual(RelayParser.totalPages(xml), 426)
    }

    func testTotalPagesMissingIsNil() {
        XCTAssertNil(RelayParser.totalPages("<result><item aid='1'/></result>"))
        XCTAssertNil(RelayParser.totalPages(""))
    }

    /// A real captured ranking response, which carries `<page num='426'/>`.
    func testLiveRankingReportsItsTotal() throws {
        let xml = try fixture("relay-rank-live.xml")
        let total = RelayParser.totalPages(xml)
        XCTAssertEqual(total, 426)
        XCTAssertEqual(RelayParser.summaries(xml).count, 10)
    }

    func testHasMoreStopsAtTheLastPage() {
        let page = NovelListPage(
            novels: [NovelSummary(id: 1, title: "x")],
            totalPages: 3
        )
        XCTAssertTrue(page.hasMore(after: 1))
        XCTAssertTrue(page.hasMore(after: 2))
        XCTAssertFalse(page.hasMore(after: 3))
        XCTAssertFalse(page.hasMore(after: 4))
    }

    /// An unknown total trusts the presence of rows rather than refusing to continue.
    func testHasMoreWithoutATotalFollowsTheRows() {
        let withRows = NovelListPage(novels: [NovelSummary(id: 1, title: "x")], totalPages: nil)
        XCTAssertTrue(withRows.hasMore(after: 1))
        let empty = NovelListPage(novels: [], totalPages: nil)
        XCTAssertFalse(empty.hasMore(after: 1))
    }

    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(
            forResource: (name as NSString).deletingPathExtension,
            withExtension: (name as NSString).pathExtension,
            subdirectory: "Fixtures"
        )
        guard let url else { throw XCTSkip("missing fixture \(name)") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
