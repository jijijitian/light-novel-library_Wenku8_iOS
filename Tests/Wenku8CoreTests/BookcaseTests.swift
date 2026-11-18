import XCTest
@testable import Wenku8Core

final class BookcaseTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil),
            "missing fixture \(name)"
        )
        return TextDecoding.decode(try Data(contentsOf: url))
    }

    func testBookcaseParsesRealRows() throws {
        let entries = DesktopParser.bookcase(try fixture("desktop-bookcase.html"))
        XCTAssertFalse(entries.isEmpty, "the desktop shelf links through readbookcase.php")
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.novel.id, 3519)
        XCTAssertTrue(first.novel.title.contains("我买下了与她的每周密会"))
        XCTAssertEqual(first.novel.author, "羽田宇佐")
        XCTAssertEqual(first.novel.coverURL?.absoluteString,
                       "https://img.wenku8.com/image/3/3519/3519s.jpg")
    }

    func testBookcaseKeepsTheRecordedChapter() throws {
        let entries = DesktopParser.bookcase(try fixture("desktop-bookcase.html"))
        let first = try XCTUnwrap(entries.first)
        let chapter = try XCTUnwrap(first.latestChapter)
        XCTAssertEqual(chapter.id, 183292)
        XCTAssertTrue(chapter.title.contains("第11话 有宫城在的地方"))
    }

    func testBookcaseDropsDuplicateBooks() {
        // The same book can be listed twice; the shelf must not show it twice.
        let row = """
        <tr><td><input type="checkbox" name="checkid[]" value="1"></td>
        <td><a href="https://www.wenku8.net/modules/article/readbookcase.php?aid=7&bid=1" target="_blank">书</a></td>
        <td><a href=authorarticle.php?author=作者>作者</a></td>
        <td><a href="https://www.wenku8.net/modules/article/readbookcase.php?aid=7&bid=1&cid=99" target="_blank">第1话</a></td></tr>
        """
        let html = "<table>\(row)\(row)</table>"
        let entries = DesktopParser.bookcase(html)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.novel.id, 7)
    }

    func testEmptyShelfYieldsNoEntries() {
        let html = "<html><body><table><tr><th>名称</th></tr></table></body></html>"
        XCTAssertTrue(DesktopParser.bookcase(html).isEmpty)
    }

    func testBookcaseWithAmpEntityEncoding() {
        // Some mirrors serve `&amp;` in the query string.
        let row = """
        <tr><td><input type="checkbox" name="checkid[]" value="5"></td>
        <td><a href="https://www.wenku8.net/modules/article/readbookcase.php?aid=42&amp;bid=5">书名</a></td>
        <td><a href=authorarticle.php?author=甲>甲</a></td>
        <td><a href="https://www.wenku8.net/modules/article/readbookcase.php?aid=42&amp;bid=5&amp;cid=77">第2话</a></td></tr>
        """
        let entries = DesktopParser.bookcase("<table>\(row)</table>")
        XCTAssertEqual(entries.first?.novel.id, 42)
        XCTAssertEqual(entries.first?.latestChapter?.id, 77)
    }

    func testShelfGroupsAreParsedWithCurrentCount() {
        let html = """
        <div class="gridtop">
        您的书架可收藏 300 本，已收藏 14 本，本组有 14 本。
        <select name="classlist" onchange="javascript:document.location='bookcase.php?classid='+this.value;">
        <option value="0" selected="selected">默认书架</option>
        <option value="1">第1组书架</option>
        <option value="2">第2组书架</option>
        </select>
        </div>
        """
        let groups = DesktopParser.shelfGroups(html)
        // Six regardless of markup: groups the page omitted are filled in.
        XCTAssertEqual(groups.count, 6)
        XCTAssertEqual(groups[0].classID, 0)
        XCTAssertEqual(groups[0].title, "默认书架")
        // Only the selected group reports a size; the others would be a guess.
        XCTAssertEqual(groups[0].count, 14)
        XCTAssertEqual(groups[1].count, 0)
        XCTAssertEqual(groups[1].title, "第1组书架")
        XCTAssertEqual(groups[2].classID, 2)
    }

    func testShelfGroupsAlwaysOfferTheSixTheSiteProvides() {
        // An unparseable page must not leave the picker empty: the site's six groups
        // are fixed, and an empty picker rendered as an ellipsis in the UI.
        let groups = DesktopParser.shelfGroups("<html><body>登录</body></html>")
        XCTAssertEqual(groups.count, 6)
        XCTAssertEqual(groups.map(\.classID), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(groups[0].title, "默认书架")
        XCTAssertEqual(groups[5].title, "第5组书架")
    }

    func testMoveToShelfDropdownDoesNotLeakIntoNames() {
        // The real page has a second dropdown that moves books between shelves, whose
        // options read "移到默认书架". Scanning the whole document mixed the two lists
        // and the group chips showed "移到默认书架" instead of "默认书架".
        let html = """
        <select name="classlist" onchange="javascript:document.location='bookcase.php?classid='+this.value;">
        <option value="0" selected="selected">默认书架</option>
        <option value="1">第1组书架</option>
        </select>
        <select name="newclassid" id="newclassid">
        <option value="-1">移出书架</option>
        <option value="0">移到默认书架</option>
        <option value="1">移到第1组书架</option>
        </select>
        """
        let groups = DesktopParser.shelfGroups(html)
        XCTAssertEqual(groups.map(\.classID), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(groups[0].title, "默认书架")
        XCTAssertEqual(groups[1].title, "第1组书架")
        XCTAssertFalse(groups.contains { $0.title.hasPrefix("移到") })
    }
}
