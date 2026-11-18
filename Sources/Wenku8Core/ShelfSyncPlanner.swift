import Foundation
import Wenku8Core

/// Works out what a shelf sync has to do.
///
/// Modelled on the Android project's `BookshelfSync`, because the guarantee it
/// protects is the one that matters: **a novel on the device but not in the cloud is
/// never dropped — it is pushed up instead.** A sync that simply overwrote the local
/// list with the server's would silently delete books the reader added while offline
/// or before signing in.
///
/// Kept as a pure function over ids so it can be tested without a network or an
/// account, and so the caller passes a single snapshot of each side (reading the
/// local shelf twice, before and after, is how the Android version once produced a
/// plan matching neither side).
public enum ShelfSyncPlanner {

    /// What a sync should do.
    public struct Plan: Equatable {
        /// On the account but not on the device: fetch and add locally.
        public var toDownloadLocally: [Int]
        /// On the device but not on the account: push up.
        public var toUploadRemotely: [Int]

        /// Nothing to pull and nothing to push, so both sides already agree.
        public var isUpToDate: Bool {
            toDownloadLocally.isEmpty && toUploadRemotely.isEmpty
        }
    }

    /// Novels on both sides whose recorded state has diverged.
    ///
    /// The counterpart of the Android project's `staleNovels`. Both sides carry the
    /// same two facts — the site's last-update date and the latest chapter id — so a
    /// mismatch means the device is showing something older than the account knows.
    /// The chapter id is the more precise of the two (a book updated twice in one day
    /// moves it while the date stands still), but both are compared: a book cached
    /// before either was recorded reads as absent rather than as different.
    ///
    /// - Parameter local: what the device has recorded, keyed by novel id.
    /// - Returns: ids to refresh, in the account's order.
    public static func staleNovels(
        cloud: [ShelfSnapshot],
        local: [Int]
    ) -> [Int] {
        let onDevice = Set(local)
        return cloud.compactMap { entry in
            // Missing locally rather than stale; `plan` already schedules it.
            guard onDevice.contains(entry.id) else { return nil }
            guard let held = entry.localLatestChapterID else {
                // No readable record: treat as stale, which also catches a cache file
                // that is missing or truncated.
                return entry.id
            }
            return held == entry.cloudLatestChapterID ? nil : entry.id
        }
    }

    /// One book's state on both sides, for the staleness comparison.
    public struct ShelfSnapshot: Equatable, Sendable {
        public var id: Int
        /// Chapter the device last recorded for this book, if it has one.
        public var localLatestChapterID: Int?
        /// Chapter the account reports as latest.
        public var cloudLatestChapterID: Int?

        public init(id: Int, localLatestChapterID: Int?, cloudLatestChapterID: Int?) {
            self.id = id
            self.localLatestChapterID = localLatestChapterID
            self.cloudLatestChapterID = cloudLatestChapterID
        }
    }

    /// Plans a sync between the device's shelf and the account's.
    ///
    /// - Parameters:
    ///   - local: ids the device has saved, in display order.
    ///   - cloud: ids the account has, in the server's order.
    ///   - adoptAllLocal: when false, local-only books are still uploaded; this exists
    ///     only so a caller can explicitly *not* adopt them. Defaults to true, which
    ///     is the behaviour the guarantee requires.
    public static func plan(local: [Int], cloud: [Int], adoptAllLocal: Bool = true) -> Plan {
        let localSet = Set(local)
        let cloudSet = Set(cloud)

        // Missing locally: the account has them and the device does not.
        let toDownload = cloud.filter { !localSet.contains($0) }

        // Present locally, absent from the account. Set difference rather than a
        // filter over a combined list, so a duplicate id on either side cannot
        // survive as a phantom "upload" of a book the account already has.
        // De-duplicated: a repeated id on the device would otherwise be uploaded
        // twice, and the second call reports "already present" for no reason.
        var seen = Set<Int>()
        let toUpload = adoptAllLocal
            ? local.filter { !cloudSet.contains($0) && seen.insert($0).inserted }
            : []

        return Plan(toDownloadLocally: toDownload, toUploadRemotely: toUpload)
    }
}
