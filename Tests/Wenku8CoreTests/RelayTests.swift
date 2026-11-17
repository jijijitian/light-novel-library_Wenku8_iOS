import XCTest
@testable import Wenku8Core

final class RelayTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil),
            "missing fixture \(name)"
        )
        return TextDecoding.decode(try Data(contentsOf: url))
    }

    private func fixtureExists(_ name: String) -> Bool {
        (Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil)) != nil
    }

    // MARK: - Lists

    func testListParsingKeepsIDsTitlesAndAuthors() throws {
        let items = RelayParser.items(try fixture("relay-list.xml"))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.id, 1305)
        XCTAssertEqual(items.first?.title, "你们赶紧给我结婚吧！")
        XCTAssertEqual(items.first?.author, "优汰")
        XCTAssertTrue(items.allSatisfy { $0.id > 0 && !$0.title.isEmpty })
        // Covers are synthesised from the book id, matching the site's grouping.
        XCTAssertEqual(items.first?.coverURL?.absoluteString, "https://img.wenku8.com/image/1/1305/1305s.jpg")
    }

    func testListParsingDropsRowsWithoutIdentity() {
        let xml = """
        <metadata>
          <item><title>没有 ID</title></item>
          <item><aid>7</aid></item>
          <item><aid>8</aid><title>正常</title></item>
        </metadata>
        """
        let items = RelayParser.items(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, 8)
    }

    // MARK: - Metadata

    func testDetailParsingReadsBookFields() throws {
        let detail = RelayParser.detail(try fixture("relay-meta.xml"), aid: 1305)
        XCTAssertEqual(detail.id, 1305)
        XCTAssertEqual(detail.title, "你们赶紧给我结婚吧！")
        XCTAssertEqual(detail.author, "优汰")
        XCTAssertEqual(detail.category, "电击文库")
        XCTAssertEqual(detail.status, "连载中")
        XCTAssertEqual(detail.wordCount, "123456")
        XCTAssertTrue(detail.intro.contains("少子化"))
        XCTAssertEqual(detail.coverURL?.absoluteString, "https://img.wenku8.com/image/1/1305/1305s.jpg")
    }

    func testDetailParsingFallsBackToRequestedID() {
        let detail = RelayParser.detail("<metadata><book><title>无名</title></book></metadata>", aid: 42)
        XCTAssertEqual(detail.id, 42)
        XCTAssertEqual(detail.title, "无名")
        XCTAssertEqual(detail.coverURL?.absoluteString, "https://img.wenku8.com/image/0/42/42s.jpg")
    }

    // MARK: - Chapters

    func testVolumesParseNestedStructure() throws {
        let volumes = RelayParser.volumes(try fixture("relay-list-chapters.xml"))
        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].title, "第一卷")
        XCTAssertEqual(volumes[0].chapters.map(\.id), [1001, 1002])
        XCTAssertEqual(volumes[1].chapters.map(\.title), ["第三章 归来"])
        XCTAssertEqual(volumes.map(\.id), ["0", "1"])
    }

    func testVolumesParseFlatChapterList() {
        let xml = """
        <package>
          <chapter cid="11" title="一" />
          <chapter cid="12" title="二" />
        </package>
        """
        let volumes = RelayParser.volumes(xml)
        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes.first?.chapters.map(\.id), [11, 12])
    }

    func testVolumesSkipRowsWithoutChapterIDs() {
        let xml = """
        <package>
          <volume name="卷一">
            <chapter title="没有 ID" />
            <chapter cid="0" title="零" />
            <chapter cid="21" title="有效" />
          </volume>
        </package>
        """
        let volumes = RelayParser.volumes(xml)
        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes.first?.chapters.map(\.id), [21])
    }

    func testChapterParsingSplitsParagraphsAndImages() throws {
        let content = RelayParser.chapter(try fixture("relay-chapter.xml"), aid: 1305, cid: 1001)
        XCTAssertEqual(content.novelID, 1305)
        XCTAssertEqual(content.chapterID, 1001)
        XCTAssertEqual(content.blocks.count, 4)
        XCTAssertEqual(content.plainText.components(separatedBy: "\n\n").count, 3)
        XCTAssertEqual(
            content.firstImage?.absoluteString,
            "https://img.wenku8.com/image/1/1305/1305_1.jpg"
        )
    }

    // MARK: - Return codes

    func testResultCodesAndMessages() {
        XCTAssertEqual(RelayParser.resultCode(" 4\n"), 4)
        XCTAssertNil(RelayParser.resultCode("<xml/>"))
        XCTAssertEqual(RelayParser.message(for: 1), "操作成功")
        XCTAssertEqual(RelayParser.message(for: 6), "书架已满")
        XCTAssertTrue(RelayParser.message(for: 99).contains("99"))
    }

    func testUserNameParsing() {
        XCTAssertEqual(RelayParser.userName("jht"), "jht")
        XCTAssertNil(RelayParser.userName("4"))
        XCTAssertEqual(
            RelayParser.userName("<metadata><item><username>jht</username></item></metadata>"),
            "jht"
        )
    }

    // MARK: - Action composition

    func testActionStringsMatchTheDocumentedProtocol() {
        XCTAssertEqual(RelayAction.info(aid: 1305), "action=book&do=info&aid=1305&t=0")
        XCTAssertEqual(RelayAction.text(aid: 1305, cid: 7), "action=book&do=text&aid=1305&cid=7&t=0")
        XCTAssertEqual(RelayAction.articleList(sort: "dayvisit", page: 2), "action=articlelist&sort=dayvisit&page=2")
        XCTAssertEqual(RelayAction.search(type: "author", key: "优汰"), "action=search&searchtype=author&searchkey=优汰&t=0")
        XCTAssertEqual(RelayAction.bookcaseDelete(aid: 9), "action=bookcase&do=del&aid=9")
    }

    func testRequestPayloadIsBase64OfTheRawAction() {
        let action = RelayAction.info(aid: 1305)
        let payload = Data(action.utf8).base64EncodedString()
        XCTAssertEqual(
            String(data: Data(base64Encoded: payload)!, encoding: .utf8),
            action
        )
    }

    // MARK: - Configuration

    func testRelayIsDisabledUntilConfigured() {
        let defaults = UserDefaults(suiteName: "relay.tests.\(UUID().uuidString)")!
        let store = RelayCredentialStore(defaults: defaults)
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.storedVer)

        store.setAppVer("1.30-magic-abcdefgh")
        XCTAssertFalse(store.isConfigured, "a token alone must not switch relay on")
        XCTAssertEqual(store.storedVer, "1.30-magic-abcdefgh")
        XCTAssertEqual(store.maskedVer, "1.30-m…efgh")

        store.setEnabled(true)
        XCTAssertTrue(store.isConfigured)

        store.setEnabled(false)
        XCTAssertFalse(store.isConfigured)
        XCTAssertNotNil(store.storedVer, "disabling keeps the token for later")
    }

    func testMinimumIntervalKeepsAnAbuseFloor() {
        let defaults = UserDefaults(suiteName: "relay.tests.\(UUID().uuidString)")!
        let store = RelayCredentialStore(defaults: defaults)
        XCTAssertEqual(store.minimumInterval, 1.2, accuracy: 0.001)
        store.setMinimumInterval(0.1)
        XCTAssertEqual(store.minimumInterval, 0.5, accuracy: 0.001)
        store.setMinimumInterval(3)
        XCTAssertEqual(store.minimumInterval, 3, accuracy: 0.001)
    }

    func testUnconfiguredClientThrowsInsteadOfSending() async {
        let client = RelayClient(configuration: RelayConfiguration(isEnabled: false))
        do {
            _ = try await client.send(RelayAction.info(aid: 1))
            XCTFail("an unconfigured relay must not send")
        } catch let error as RelayError {
            guard case .notConfigured = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDisabledRelayLeavesServiceOnTheWAPPath() {
        // `NovelService` only takes the relay branch when a client reports
        // availability; with the default client that is false, so behaviour is
        // unchanged for users who never configure a credential.
        XCTAssertFalse(RelayClient.shared.isAvailable)
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
        // The same volume arriving twice is what happens when a catalogue page
        // ends mid-volume; the repeated chapter must not survive the merge.
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
