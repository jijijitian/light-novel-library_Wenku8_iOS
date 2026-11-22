import XCTest
@testable import Wenku8Core

final class RankBoardTests: XCTestCase {
    /// Every board the site serves must be reachable in the app.
    ///
    /// Measured against the live service: all of these answer with ten rows. `anime`
    /// answers empty there, so it is listed but reported as having no data.
    func testEveryRelayBoardExists() {
        let served = [
            "dayvisit", "dayvote", "weekvisit", "weekvote", "monthvisit", "monthvote",
            "allvisit", "allvote", "postdate", "lastupdate", "goodnum", "size", "fullflag",
        ]
        let cases = Set(RankBoard.allCases.map(\.rawValue))
        for sort in served {
            XCTAssertTrue(cases.contains(sort), "board \(sort) is served but missing")
        }
    }

    /// `sort` is sent verbatim as the site's parameter, so the raw values must match
    /// what the service expects rather than any local spelling.
    func testSortParameterMatchesService() {
        XCTAssertEqual(RankBoard.dayvisit.rawValue, "dayvisit")
        XCTAssertEqual(RankBoard.fullflag.rawValue, "fullflag")
        XCTAssertEqual(RankBoard.lastupdate.rawValue, "lastupdate")
    }

    func testFullFlagHasATitle() {
        XCTAssertEqual(RankBoard.fullflag.title, "已完结作品")
        XCTAssertFalse(RankBoard.fullflag.symbol.isEmpty)
    }
}
