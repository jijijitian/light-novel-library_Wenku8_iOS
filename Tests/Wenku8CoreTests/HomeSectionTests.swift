import XCTest
@testable import Wenku8Core

final class HomeSectionTests: XCTestCase {
    /// Each home row must open the board its title names.
    ///
    /// 每周书单 pointed at 总收藏榜, so tapping it showed an all-time list under a
    /// weekly heading — the row and the board disagreed.
    func testEachSectionMapsToTheBoardItsTitleNames() {
        XCTAssertEqual(HomeSection.hot.board, .dayvisit)
        XCTAssertEqual(HomeSection.latest.board, .lastupdate)
        XCTAssertEqual(HomeSection.newcomer.board, .postdate)
        XCTAssertEqual(HomeSection.weekly.board, .weekvisit)
    }

    /// The weekly row is weekly, not an all-time board.
    func testWeeklyIsNotAnAllTimeBoard() {
        XCTAssertNotEqual(HomeSection.weekly.board, .goodnum)
        XCTAssertNotEqual(HomeSection.weekly.board, .allvisit)
        XCTAssertEqual(HomeSection.weekly.board.rawValue.hasPrefix("week"), true)
    }
}
