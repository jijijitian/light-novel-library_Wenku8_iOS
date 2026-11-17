import XCTest
@testable import Wenku8Core

final class AccountParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "missing fixture \(name)"
        )
        return TextDecoding.decode(try Data(contentsOf: url))
    }

    func testDesktopLoginRejectionMessage() throws {
        let html = try fixture("login-error.html")
        XCTAssertTrue(html.contains("错误原因") || html.contains("出现错误"))
        let message = try XCTUnwrap(AccountParser.loginErrorMessage(html))
        XCTAssertTrue(message.contains("用户不存在"), "message was: \(message)")
        XCTAssertFalse(message.contains("<"))
    }

    func testLoginErrorAbsentOnNormalPage() throws {
        XCTAssertNil(AccountParser.loginErrorMessage(try fixture("articleinfo.wml")))
        XCTAssertNil(AccountParser.loginErrorMessage(try fixture("home.wml")))
    }

    func testWAPLoginMessage() throws {
        let html = try fixture("wap-login-error.wml")
        let message = try XCTUnwrap(AccountParser.wapLoginMessage(html))
        XCTAssertTrue(message.contains("用户不存在"), "message was: \(message)")
    }

    func testWAPLoginGateDetection() throws {
        XCTAssertTrue(AccountParser.isLoginGate(try fixture("wap-login-gate.wml")))
        XCTAssertTrue(AccountParser.isLoginGate(try fixture("toplist-login.wml")))
        XCTAssertFalse(AccountParser.isLoginGate(try fixture("home.wml")))
        XCTAssertFalse(AccountParser.isLoginGate(try fixture("articleinfo.wml")))
    }

    func testAccountNameIsNilForGuest() throws {
        XCTAssertNil(AccountParser.accountName(try fixture("home.wml")))
        XCTAssertNil(AccountParser.accountName(try fixture("wap-login-gate.wml")))
    }

    func testAccountNameParsedFromHeader() {
        let html = "<card><p>您好!季昊天,<a href=\"/wap/login.php\">退出</a><br/>"
        XCTAssertEqual(AccountParser.accountName(html), "季昊天")
    }

    func testMutationOutcomeRecognisesLoginGate() throws {
        let outcome = AccountParser.mutationOutcome(try fixture("wap-login-gate.wml"), novelID: 4086)
        XCTAssertEqual(outcome, .notSignedIn)
    }

    func testMutationOutcomeSuccessOnMsgwin() {
        let html = #"<card id="msgwin" title="提示"><p>已加入书架</p></card>"#
        XCTAssertEqual(AccountParser.mutationOutcome(html, novelID: 1), .succeeded)
    }

    func testMutationOutcomeDuplicateAndFull() {
        let dup = #"新书</a><br/>该小说已经在书架中<br/><p align="center">"#
        XCTAssertEqual(AccountParser.mutationOutcome(dup, novelID: 1), .alreadyPresent)
        let full = #"新书</a><br/>书架已满<br/><p align="center">"#
        XCTAssertEqual(AccountParser.mutationOutcome(full, novelID: 1), .shelfFull)
        let absent = #"新书</a><br/>该小说不在书架中<br/><p align="center">"#
        XCTAssertEqual(AccountParser.mutationOutcome(absent, novelID: 1), .notPresent)
    }

    func testBookcaseListingReusesNovelLinks() throws {
        let html = """
        <a href="/wap/article/articleinfo.php?id=4086">你们赶紧给我结婚吧！</a>
        <a href="/wap/article/articleinfo.php?id=2580">关于我在无意间被隔壁的天使变成废柴这件事</a>
        """
        let novels = AccountParser.bookcaseNovels(html)
        XCTAssertEqual(novels.map(\.id), [4086, 2580])
        XCTAssertEqual(novels.first?.coverURL?.absoluteString,
                       "https://img.wenku8.com/image/4/4086/4086s.jpg")
    }
}
