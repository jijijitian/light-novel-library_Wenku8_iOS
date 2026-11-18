import XCTest
@testable import Wenku8Core

final class RelayBookcaseTests: XCTestCase {
    /// The shape `action=bookcase&do=list` actually returns.
    func testIdOnlyListing() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <metadata>
        <book aid="3988" />
        <book aid="1508" />
        </metadata>
        """
        let entries = RelayParser.bookcaseEntries(xml)
        XCTAssertEqual(entries.map(\.aid), [3988, 1508])
    }

    /// The fuller shape: `aid` must not swallow the following `date` attribute.
    func testFullerListingDoesNotSwallowTheDate() {
        let xml = """
        <metadata>
        <book aid="3988" date="2026-08-23">
        <name><![CDATA[a novel]]></name>
        </book>
        <book aid="1508" date="2026-08-21">
        </book>
        </metadata>
        """
        let entries = RelayParser.bookcaseEntries(xml)
        XCTAssertEqual(entries.map(\.aid), [3988, 1508])
        XCTAssertEqual(entries[0].date, "2026-08-23")
        XCTAssertEqual(entries[0].name, "a novel")
        XCTAssertNil(entries[1].name)
    }

    /// One broken record must not cost the reader the rest of the shelf.
    func testBrokenEntryIsSkippedNotFatal() {
        let xml = """
        <metadata>
        <book aid="abc" />
        <book aid="1508" />
        </metadata>
        """
        XCTAssertEqual(RelayParser.bookcaseEntries(xml).map(\.aid), [1508])
    }

    func testEmptyListing() {
        XCTAssertTrue(RelayParser.bookcaseEntries("<metadata></metadata>").isEmpty)
        XCTAssertTrue(RelayParser.bookcaseEntries("").isEmpty)
    }

    /// The shelf row's `bid` is what the group-move form posts, not the `aid`.
    func testBookcaseBidIsReadForGroupMove() {
        let html = """
        <tr><td><input type="checkbox" name="checkid[]" value="12549825"></td>
        <td><a href="https://www.wenku8.net/modules/article/readbookcase.php?aid=3519&bid=12549825">书名</a></td></tr>
        """
        XCTAssertEqual(DesktopParser.bookcaseBid(forAid: 3519, in: html), 12549825)
        XCTAssertNil(DesktopParser.bookcaseBid(forAid: 9999, in: html))
    }
}
