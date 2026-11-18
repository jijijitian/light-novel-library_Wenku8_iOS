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
