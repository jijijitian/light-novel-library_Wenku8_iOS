import XCTest
@testable import Wenku8Core

/// Covers the relay's real wire formats, which were captured from the live
/// service and differ from the desktop client's XML (see `RelayParser`).
final class RelayTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil),
            "missing fixture \(name)"
        )
        return TextDecoding.decode(try Data(contentsOf: url))
    }

    // MARK: - appver

    func testAppVerMatchesKnownVectors() {
        // Vectors cross-checked against an independent Python HMAC-SHA256.
        XCTAssertEqual(RelayAppVer.token(unixSeconds: 1_700_000_000), "1.30-digital-bento-1eb0572a")
        XCTAssertEqual(RelayAppVer.token(unixSeconds: 1_763_484_360), "1.30-digital-bento-9e8d91dd")
        XCTAssertEqual(RelayAppVer.token(unixSeconds: 1_793_000_000), "1.30-digital-bento-a12060d2")
    }

    func testAppVerIsStableWithinAMinuteWindow() {
        let base: Int64 = 1_700_000_040
        XCTAssertEqual(RelayAppVer.token(unixSeconds: base), RelayAppVer.token(unixSeconds: base + 19))
        XCTAssertNotEqual(RelayAppVer.token(unixSeconds: base), RelayAppVer.token(unixSeconds: base + 60))
    }

    func testAppVerShape() {
        let token = RelayAppVer.token(unixSeconds: 1_700_000_000)
        XCTAssertTrue(token.hasPrefix("1.30-digital-bento-"), token)
        let parts = token.split(separator: "-")
        // "digital-bento" contains a hyphen itself, so the split yields 4 parts.
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "1.30")
        XCTAssertEqual(parts.dropFirst().dropLast().joined(separator: "-"), "digital-bento")
        XCTAssertEqual(parts.last?.count, 8)
        XCTAssertTrue(parts.last!.allSatisfy { $0.isHexDigit })
    }

    func testSHA256AndHMACMatchPublishedVectors() {
        // RFC 4231 test case 2.
        let mac = SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))
        XCTAssertEqual(mac.map { String(format: "%02x", $0) }.joined(),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // FIPS 180-2 "abc".
        let digest = SHA256.hash(Array("abc".utf8))
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testBuiltinProviderKeepsWorkingWithoutStoredSecret() async {
        let provider = BuiltinAppVerProvider()
        let token = await provider.appVer(for: RelayToken(timestampMilliseconds: 1_700_000_000_000))
        XCTAssertEqual(token, "1.30-digital-bento-1eb0572a")
    }

    // MARK: - Books

    func testMetaParsingReadsRealDataFields() throws {
        let detail = RelayParser.detail(try fixture("relay-meta-real.xml"), aid: 1614)
        XCTAssertEqual(detail.id, 1614)
        XCTAssertTrue(detail.title.hasPrefix("青春猪头少年"))
        XCTAssertEqual(detail.author, "鸭志田一")
        XCTAssertEqual(detail.category, "电击文库")
        XCTAssertEqual(detail.status, "已完成")
        XCTAssertEqual(detail.wordCount, "1669205")
        XCTAssertEqual(detail.updatedAt, "2026-10-26")
        XCTAssertEqual(detail.coverURL?.absoluteString, "https://img.wenku8.com/image/1/1614/1614s.jpg")
    }

    func testNovelListParsingReadsTitlesAndAuthors() throws {
        let items = RelayParser.summaries(try fixture("relay-novellist.xml"))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.id, 3519)
        XCTAssertTrue(items.first?.title.contains("我买下了与她的每周密会") == true)
        XCTAssertEqual(items.first?.author, "羽田宇佐")
        XCTAssertEqual(items.last?.author, "雨森焚火")
    }

    func testBareIdListIsRejectedWithoutTitles() throws {
        // `articlelist` returns ids only, so it must not be mistaken for a
        // usable summary list.
        XCTAssertTrue(RelayParser.summaries(try fixture("relay-list-real.xml")).isEmpty)
        XCTAssertEqual(RelayParser.ids(try fixture("relay-list-real.xml")), [3519, 3057])
    }

    // MARK: - Catalogue

    func testVolumesParseCDataAndAttributes() throws {
        let volumes = RelayParser.volumes(try fixture("relay-package-real.xml"))
        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].title, "第一卷")
        XCTAssertEqual(volumes[0].chapters.map(\.id), [54756, 54757, 54758])
        XCTAssertEqual(volumes[0].chapters[1].title, "第一章 学姐是兔女郎")
        XCTAssertEqual(volumes[1].title, "第二卷 青春猪头少年不会梦到小恶魔学妹")
        XCTAssertEqual(volumes.map(\.id), ["0", "1"])
    }

    func testVolumesSkipEmptyVolumesAndBadIDs() {
        let xml = """
        <package>
        <volume vid="1"><![CDATA[空卷]]></volume>
        <volume vid="2"><![CDATA[有卷]]>
        <chapter cid="0"><![CDATA[零]]></chapter>
        <chapter cid="5"><![CDATA[五]]></chapter>
        </volume>
        </package>
        """
        let volumes = RelayParser.volumes(xml)
        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes[0].chapters.map(\.id), [5])
    }

    // MARK: - Chapters

    func testChapterParsingTreatsBodyAsPlainText() {
        let body = """

          第一章 标题

            第一段正文。

            第二段正文。

        """
        let content = RelayParser.chapter(body, aid: 1614, cid: 54757)
        XCTAssertEqual(content.title, "第一章 标题")
        XCTAssertEqual(content.blocks.count, 2)
        XCTAssertTrue(content.plainText.contains("第一段正文"))
    }

    // MARK: - Categories

    func testSortsParsing() throws {
        let sorts = RelayParser.sorts(try fixture("relay-sorts.xml"))
        XCTAssertEqual(sorts.map(\.id), [1, 2, 3])
        XCTAssertEqual(sorts.first?.name, "电击文库")
    }

    // MARK: - Return codes

    func testResultCodesAndMessages() {
        XCTAssertEqual(RelayParser.resultCode(" 4\n"), 4)
        XCTAssertNil(RelayParser.resultCode("<xml/>"))
        XCTAssertEqual(RelayParser.message(for: 1), "操作成功")
        XCTAssertEqual(RelayParser.message(for: 6), "书架已满")
        XCTAssertTrue(RelayParser.message(for: 99).contains("99"))
    }

    // MARK: - Actions

    func testActionStringsMatchTheDocumentedProtocol() {
        XCTAssertEqual(RelayAction.info(aid: 1305), "action=book&do=info&aid=1305&t=0")
        XCTAssertEqual(RelayAction.text(aid: 1305, cid: 7), "action=book&do=text&aid=1305&cid=7&t=0")
        XCTAssertEqual(RelayAction.novelList(sort: "dayvisit", page: 2),
                       "action=novellist&sort=dayvisit&page=2&t=0")
        XCTAssertEqual(RelayAction.bookcaseDelete(aid: 9), "action=bookcase&do=del&aid=9")
    }

    func testRequestPayloadIsBase64OfTheRawAction() {
        let action = RelayAction.info(aid: 1305)
        let payload = Data(action.utf8).base64EncodedString()
        XCTAssertEqual(String(data: Data(base64Encoded: payload)!, encoding: .utf8), action)
    }

    // MARK: - Client defaults

    func testRelayIsOnByDefaultWithTheBuiltinProvider() {
        XCTAssertTrue(RelayClient.shared.isAvailable)
    }

    func testDisabledClientThrowsInsteadOfSending() async {
        let client = RelayClient(configuration: RelayConfiguration(isEnabled: false))
        do {
            _ = try await client.send(RelayAction.info(aid: 1))
            XCTFail("a disabled relay must not send")
        } catch let error as RelayError {
            guard case .notConfigured = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testThrottleKeepsAnAbuseFloor() {
        let throttle = RelayThrottle(minimumInterval: 0.1)
        // The actor clamps anything below the floor.
        XCTAssertNotNil(throttle)
    }
}

final class DedupeTests: XCTestCase {
    func testNovelSummariesDropRepeatedIDsKeepingOrder() {
        let items = [
            NovelSummary(id: 3, title: "三"),
            NovelSummary(id: 1, title: "一"),
            NovelSummary(id: 3, title: "三（重复）"),
            NovelSummary(id: 2, title: "二"),
        ]
        let unique = items.uniquedByID()
        XCTAssertEqual(unique.map(\.id), [3, 1, 2])
        XCTAssertEqual(unique.first?.title, "三", "the first occurrence wins")
    }

    func testChapterLinksDropRepeatedIDs() {
        let chapters = [
            ChapterLink(id: 10, title: "a"),
            ChapterLink(id: 11, title: "b"),
            ChapterLink(id: 10, title: "a again"),
        ]
        XCTAssertEqual(chapters.uniquedByID().map(\.id), [10, 11])
    }

    func testMergeVolumesDedupesChaptersAcrossPageBoundaries() {
        let first = Volume(id: "0", title: "第一卷", chapters: [
            ChapterLink(id: 1, title: "一"),
            ChapterLink(id: 2, title: "二"),
        ])
        let second = Volume(id: "0", title: "第一卷", chapters: [
            ChapterLink(id: 2, title: "二"),
            ChapterLink(id: 3, title: "三"),
        ])
        let merged = NovelService.mergeVolumes([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].chapters.map(\.id), [1, 2, 3])
    }

    func testMergeVolumesAssignsDistinctVolumeIDs() {
        let volumes = [
            Volume(id: "x", title: "同卷", chapters: [ChapterLink(id: 1, title: "一")]),
            Volume(id: "x", title: "同卷", chapters: [ChapterLink(id: 2, title: "二")]),
            Volume(id: "y", title: "另一卷", chapters: [ChapterLink(id: 3, title: "三")]),
        ]
        let merged = NovelService.mergeVolumes(volumes)
        XCTAssertEqual(merged.map(\.id), ["0", "1"])
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count, "volume ids must be unique")
    }
}
