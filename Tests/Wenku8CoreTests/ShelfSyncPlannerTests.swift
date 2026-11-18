import XCTest
@testable import Wenku8Core

final class ShelfSyncPlannerTests: XCTestCase {
    /// The guarantee the whole module exists for: a book the reader saved locally
    /// must be uploaded, never silently dropped, when the account does not have it.
    func testLocalOnlyNovelIsUploadedNotDropped() {
        let plan = ShelfSyncPlanner.plan(local: [1, 2], cloud: [2, 3])
        XCTAssertEqual(plan.toUploadRemotely, [1])
        XCTAssertEqual(plan.toDownloadLocally, [3])
    }

    func testAlreadyInSyncNeedsNothing() {
        let plan = ShelfSyncPlanner.plan(local: [1, 2, 3], cloud: [3, 2, 1])
        XCTAssertTrue(plan.isUpToDate)
    }

    func testEmptyCloudUploadsEverything() {
        let plan = ShelfSyncPlanner.plan(local: [7, 8], cloud: [])
        XCTAssertEqual(plan.toUploadRemotely, [7, 8])
        XCTAssertTrue(plan.toDownloadLocally.isEmpty)
    }

    func testEmptyLocalDownloadsEverything() {
        let plan = ShelfSyncPlanner.plan(local: [], cloud: [5, 6])
        XCTAssertEqual(plan.toDownloadLocally, [5, 6])
        XCTAssertTrue(plan.toUploadRemotely.isEmpty)
    }

    /// A duplicated id must not turn into a phantom upload of a book the account
    /// already has.
    func testDuplicatesDoNotProduceSpuriousUploads() {
        let plan = ShelfSyncPlanner.plan(local: [1, 1, 2], cloud: [2])
        XCTAssertEqual(plan.toUploadRemotely, [1])
    }

    func testOrderFollowsEachSide() {
        let plan = ShelfSyncPlanner.plan(local: [9, 8, 7], cloud: [3, 1, 2])
        XCTAssertEqual(plan.toUploadRemotely, [9, 8, 7])
        XCTAssertEqual(plan.toDownloadLocally, [3, 1, 2])
    }
}

final class ShelfStaleTests: XCTestCase {
    /// Both sides agree on the latest chapter: nothing to refetch.
    func testMatchingChaptersAreNotStale() {
        let cloud = [
            ShelfSyncPlanner.ShelfSnapshot(
                id: 1, localLatestChapterID: 100, cloudLatestChapterID: 100
            ),
        ]
        XCTAssertTrue(ShelfSyncPlanner.staleNovels(cloud: cloud, local: [1]).isEmpty)
    }

    /// The account moved on: the device is showing an older catalogue.
    func testMovedChapterIsStale() {
        let cloud = [
            ShelfSyncPlanner.ShelfSnapshot(
                id: 1, localLatestChapterID: 100, cloudLatestChapterID: 101
            ),
        ]
        XCTAssertEqual(ShelfSyncPlanner.staleNovels(cloud: cloud, local: [1]), [1])
    }

    /// No readable local record counts as stale rather than as "unchanged", which is
    /// what catches a missing or truncated cache file.
    func testMissingLocalRecordIsStale() {
        let cloud = [
            ShelfSyncPlanner.ShelfSnapshot(
                id: 7, localLatestChapterID: nil, cloudLatestChapterID: 5
            ),
        ]
        XCTAssertEqual(ShelfSyncPlanner.staleNovels(cloud: cloud, local: [7]), [7])
    }

    /// A book the device does not have is missing, not stale; `plan` covers it.
    func testAbsentLocallyIsNotStale() {
        let cloud = [
            ShelfSyncPlanner.ShelfSnapshot(
                id: 9, localLatestChapterID: nil, cloudLatestChapterID: 3
            ),
        ]
        XCTAssertTrue(ShelfSyncPlanner.staleNovels(cloud: cloud, local: []).isEmpty)
    }

    /// Order follows the account's listing, so refreshes happen in the visible order.
    func testOrderFollowsCloud() {
        let cloud = [
            ShelfSyncPlanner.ShelfSnapshot(id: 3, localLatestChapterID: 1, cloudLatestChapterID: 2),
            ShelfSyncPlanner.ShelfSnapshot(id: 1, localLatestChapterID: 5, cloudLatestChapterID: 6),
        ]
        XCTAssertEqual(ShelfSyncPlanner.staleNovels(cloud: cloud, local: [3, 1]), [3, 1])
    }
}
