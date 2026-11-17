import XCTest
@testable import Wenku8Core

final class OfflineStoreTests: XCTestCase {
    private var root: URL!
    private var store: OfflineStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = OfflineStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func content(cid: Int, images: [URL] = []) -> ChapterContent {
        var blocks: [ChapterContent.Block] = [.paragraph("第 \(cid) 章正文")]
        blocks.append(contentsOf: images.map { .image($0) })
        return ChapterContent(novelID: 1614, chapterID: cid, title: "第 \(cid) 章", blocks: blocks)
    }

    private func entry(ids: [Int], stored: Set<Int> = []) -> OfflineStore.Entry {
        OfflineStore.Entry(
            novelID: 1614,
            title: "测试小说",
            author: "作者",
            chapterIDs: ids,
            chapterTitles: Dictionary(uniqueKeysWithValues: ids.map { ($0, "第 \($0) 章") }),
            storedChapterIDs: stored,
            coverFile: nil,
            updatedAt: Date(),
            bytes: 0
        )
    }

    // MARK: - Chapters

    func testChapterRoundTrips() async throws {
        let original = content(cid: 54757)
        await store.saveChapter(original, for: 1614)
        let loaded = await store.chapter(1614, cid: 54757)
        XCTAssertEqual(loaded?.chapterID, 54757)
        XCTAssertEqual(loaded?.title, "第 54757 章")
        XCTAssertEqual(loaded?.plainText, "第 54757 章正文")
    }

    func testMissingChapterIsNilNotAnError() async {
        let loaded = await store.chapter(1614, cid: 999)
        XCTAssertNil(loaded)
    }

    func testHasChapterReflectsDisk() async {
        var has = await store.hasChapter(1614, cid: 1)
        XCTAssertFalse(has)
        await store.saveChapter(content(cid: 1), for: 1614)
        has = await store.hasChapter(1614, cid: 1)
        XCTAssertTrue(has)
    }

    // MARK: - Manifest

    func testManifestRoundTripsAndComputesProgress() async throws {
        await store.saveManifest(entry(ids: [1, 2, 3, 4], stored: [1, 2]))
        let loadedRaw = await store.entry(for: 1614)
        let loaded = try XCTUnwrap(loadedRaw)
        XCTAssertEqual(loaded.chapterIDs.count, 4)
        XCTAssertEqual(loaded.storedChapterIDs, [1, 2])
        XCTAssertEqual(loaded.progress, 0.5, accuracy: 0.001)
        XCTAssertFalse(loaded.isComplete)
    }

    func testCompleteEntry() async throws {
        await store.saveManifest(entry(ids: [1, 2], stored: [1, 2]))
        let loadedRaw = await store.entry(for: 1614)
        let loaded = try XCTUnwrap(loadedRaw)
        XCTAssertTrue(loaded.isComplete)
        XCTAssertEqual(loaded.progress, 1.0, accuracy: 0.001)
    }

    func testEntriesListsEverythingStored() async throws {
        await store.saveManifest(entry(ids: [1], stored: [1]))
        var other = entry(ids: [9], stored: [])
        other.novelID = 4086
        other.title = "另一本"
        await store.saveManifest(other)

        let all = await store.entries()
        XCTAssertEqual(Set(all.map(\.novelID)), [1614, 4086])
    }

    func testEmptyManifestHasZeroProgressNotNaN() async {
        await store.saveManifest(entry(ids: [], stored: []))
        let loaded = await store.entry(for: 1614)
        XCTAssertEqual(loaded?.progress, 0)
        XCTAssertFalse(loaded?.isComplete ?? true)
    }

    // MARK: - Images

    func testImageIsAddressableByURLHash() async throws {
        let remote = URL(string: "https://pic.777743.xyz/1/1614/54785/67547.jpg")!
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

        let absent = await store.imageURL(for: 1614, remote: remote)
        XCTAssertNil(absent)

        await store.saveImage(data, for: 1614, remote: remote)
        let resolved = await store.imageURL(for: 1614, remote: remote)
        let found = try XCTUnwrap(resolved)
        XCTAssertEqual(try Data(contentsOf: found), data)
        let other = await store.imageURL(for: 1614, remote: URL(string: "https://x/y.jpg")!)
        XCTAssertNil(other)
    }

    func testImageFileNameIsStableAndUnique() {
        let a = URL(string: "https://pic.777743.xyz/1/1614/54785/67547.jpg")!
        let b = URL(string: "https://pic.777743.xyz/1/1614/54785/67548.jpg")!
        XCTAssertEqual(OfflineStore.imageFileName(for: a), OfflineStore.imageFileName(for: a))
        XCTAssertNotEqual(OfflineStore.imageFileName(for: a), OfflineStore.imageFileName(for: b))
        XCTAssertTrue(OfflineStore.imageFileName(for: a).hasSuffix(".img"))
    }

    // MARK: - Deletion

    func testDeleteRemovesOnlyThatBook() async throws {
        await store.saveChapter(content(cid: 1), for: 1614)
        await store.saveManifest(entry(ids: [1], stored: [1]))
        var other = entry(ids: [2], stored: [2])
        other.novelID = 4086
        await store.saveManifest(other)
        await store.saveChapter(content(cid: 2), for: 4086)

        await store.delete(1614)

        let goneChapter = await store.chapter(1614, cid: 1)
        let goneEntry = await store.entry(for: 1614)
        let keptEntry = await store.entry(for: 4086)
        XCTAssertNil(goneChapter)
        XCTAssertNil(goneEntry)
        XCTAssertNotNil(keptEntry)
    }

    func testUsedBytesGrowsWithChapters() async throws {
        let before = await store.usedBytes(for: 1614)
        await store.saveChapter(content(cid: 1), for: 1614)
        let after = await store.usedBytes(for: 1614)
        XCTAssertGreaterThan(after, before)
    }

    // MARK: - Entry construction

    func testMakeEntryFlattensVolumesAndKeepsExistingProgress() async throws {
        await store.saveManifest(entry(ids: [10, 11], stored: [10]))

        let detail = NovelDetail(id: 1614, title: "测试小说", author: "作者")
        let volumes = [
            Volume(id: "0", title: "第一卷", chapters: [
                ChapterLink(id: 10, title: "一"),
                ChapterLink(id: 11, title: "二"),
            ]),
            Volume(id: "1", title: "第二卷", chapters: [
                ChapterLink(id: 12, title: "三"),
            ]),
        ]
        let built = await store.makeEntry(detail: detail, volumes: volumes, coverFile: nil)
        XCTAssertEqual(built.chapterIDs, [10, 11, 12])
        XCTAssertEqual(built.chapterTitles[12], "三")
        XCTAssertEqual(built.storedChapterIDs, [10], "previous progress is preserved")
    }
}
