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
