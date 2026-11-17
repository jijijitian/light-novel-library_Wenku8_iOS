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

final class DesktopAccountTests: XCTestCase {
    func testAnonymousBannerIsNotAnAccount() {
        let html = "轻小说文库欢迎您，您可以选择[<a href=\"/login.php\">登录</a>]或者[<a href=\"/register.php\">注册新用户</a>]！"
        XCTAssertNil(AccountParser.desktopAccountName(html))
    }

    func testSignedInBannerYieldsTheName() {
        XCTAssertEqual(AccountParser.desktopAccountName("轻小说文库欢迎您，鸭志田一！"), "鸭志田一")
        XCTAssertEqual(AccountParser.desktopAccountName("轻小说文库欢迎您，测试用户！"), "测试用户")
    }

    func testBannerWithLogoutLink() {
        let html = "欢迎您，alice！ [<a href=\"/logout.php\">退出</a>]"
        XCTAssertEqual(AccountParser.desktopAccountName(html), "alice")
    }

    func testPageWithoutBannerIsNil() {
        XCTAssertNil(AccountParser.desktopAccountName("<html><body>no header</body></html>"))
    }

    func testOnlyTheFormCountsAsALoginPage() {
        // Ordinary pages link to login.php?jumpurl=… and must not be mistaken for
        // the login form; that misdetection used to break session checks.
        XCTAssertFalse(AccountParser.isDesktopLoginPage(
            "<a href=\"https://www.wenku8.net/login.php?jumpurl=%2Fbook%2F1614.htm\">登录</a>"
        ))
        XCTAssertTrue(AccountParser.isDesktopLoginPage(
            "<form name=\"frmlogin\" method=\"post\" action=\"login.php?do=submit\">"
        ))
    }

    func testDomainEndpointsPutTheChosenMirrorFirst() {
        let net = SiteEndpoints(domain: .net)
        XCTAssertEqual(net.primaryHost, "https://www.wenku8.net")
        XCTAssertEqual(net.hosts.last, "https://www.wenku8.cc")
        let cc = SiteEndpoints(domain: .cc)
        XCTAssertEqual(cc.primaryHost, "https://www.wenku8.cc")
        XCTAssertEqual(cc.hosts.last, "https://www.wenku8.net")
        XCTAssertEqual(cc.primaryWAP, "https://www.wenku8.cc/wap")
    }

    func testClientSwitchesDomain() {
        let client = Wenku8Client()
        client.use(domain: .cc)
        XCTAssertEqual(client.endpoints.primaryHost, "https://www.wenku8.cc")
        client.use(domain: .net)
        XCTAssertEqual(client.endpoints.primaryHost, "https://www.wenku8.net")
    }
}
