import XCTest
@testable import Wenku8Core

final class CookieStoreTests: XCTestCase {
    /// The relay's cookie has to survive a relaunch; before this the shelf was empty
    /// after every restart until the reader signed in again.
    ///
    /// Tests the encoding step directly: `HTTPCookieStorage.shared` is not backed by a
    /// persistent store on this platform, so a round trip through it would fail for a
    /// reason unrelated to the code under test.
    func testRelayCookieEncodingRoundTrips() {
        let cookie = HTTPCookie(properties: [
            .domain: "wenku8-relay.mewx.org",
            .path: "/",
            .name: "PHPSESSID",
            .value: "abc123",
            .secure: "TRUE",
        ])!

        let data = SharedCookieStore.encode([cookie])
        XCTAssertNotNil(data)

        let decoded = data.flatMap(SharedCookieStore.decode)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.name, "PHPSESSID")
        XCTAssertEqual(decoded?.first?.value, "abc123")
        XCTAssertEqual(decoded?.first?.domain, "wenku8-relay.mewx.org")
    }

    /// A website cookie must never be treated as a relay cookie: signing out of the
    /// relay must not sign the reader out of wenku8.net.
    func testWebsiteCookieIsNotClassifiedAsRelay() {
        XCTAssertFalse(RelayHost.isRelay("www.wenku8.net"))
        XCTAssertFalse(RelayHost.isRelay(".wenku8.net"))
        XCTAssertTrue(RelayHost.isRelay("wenku8-relay.mewx.org"))
    }

    func testHostMatching() {
        XCTAssertTrue(RelayHost.isRelay("wenku8-relay.mewx.org"))
        XCTAssertTrue(RelayHost.isRelay(".mewx.org"))
        XCTAssertFalse(RelayHost.isRelay("www.wenku8.net"))
        XCTAssertFalse(RelayHost.isRelay("wenku8.cc"))
    }
}
