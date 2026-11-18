import Foundation
import SwiftUI
import Wenku8Core

/// Tracks the signed-in state and keeps the remote bookcase in sync with the
/// site. The site is the source of truth; `LibraryStore` only holds the local
/// copy that makes the shelf usable offline.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var userName: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncingShelf = false
    @Published private(set) var remoteNovels: [NovelSummary] = []
    /// The shelf rows as the site reports them, including the chapter it has
    /// recorded for each book.
    @Published private(set) var remoteShelf: [ShelfEntry] = []
    @Published private(set) var pendingAdds = Set<Int>()
    /// The six groups the site always offers. Declared, not fetched: the names never
    /// change, and only the counts do.
    @Published private(set) var shelfGroups: [DesktopParser.ShelfGroup] =
        DesktopParser.fixedShelfGroups
    /// Per-group counts, cached so the chips show real figures before any refresh.
    @Published private(set) var shelfGroupCounts: [Int: Int] = [:]
    /// Which group the shelf view is showing. `0` is 默认书架.
    @Published var selectedShelfClass = 0

    private let service: NovelService
    private let defaults = UserDefaults.standard
    private let nameKey = "wenku8.accountName"

    var isSignedIn: Bool { userName != nil }

    init(service: NovelService = NovelService()) {
        self.service = service
        userName = defaults.string(forKey: nameKey)
        if userName != nil {
            Task { await refreshUserName() }
        }
    }

    #if DEBUG
    /// Debug-only: signs in from environment variables so automated runs (and
    /// simulator checks) can exercise the real login path without UI scripting.
    func debugSignInIfConfigured() async {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["WENKU8_LOGIN_USER"], !user.isEmpty,
              let pass = env["WENKU8_LOGIN_PASS"], !pass.isEmpty,
              !isSignedIn else { return }
        _ = await signIn(username: user, password: pass)
    }
    #endif

    /// Refreshes the cached display name; drops it when the session expired.
    func refreshUserName() async {
        let current = await service.accountName()
        if let current {
            setUserName(current)
        } else if Wenku8Client.shared.hasSession() {
            // A cookie exists but the header says 游客: the session went stale.
            setUserName(nil)
        }
    }

    func signIn(username: String, password: String) async -> Bool {
        guard !isSigningIn else { return false }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }
        do {
            let session = try await service.signIn(username: username, password: password)
            setUserName(session.userName)
            await syncShelf()
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func signOut() {
        service.signOut()
        setUserName(nil)
        remoteNovels = []
        remoteShelf = []
        lastError = nil
    }

    /// Pulls the site's bookcase so the app can show it next to the local shelf.
    ///
    /// Reading the groups and the selected group's rows happens on every sync: the
    /// group list carries per-group counts, and only the request we just made has an
    /// accurate figure for the group it rendered.
    func syncShelf() async {
        guard isSignedIn, !isSyncingShelf else { return }
        isSyncingShelf = true
        defer { isSyncingShelf = false }

        if let page = try? await service.remoteShelfPage(classID: selectedShelfClass) {
            apply(page: page, classID: selectedShelfClass)
        }
    }

    /// Installs a fetched group: rows, the site's own count, and the local cache.
    private func apply(
        page: (entries: [ShelfEntry], reportedCount: Int?),
        classID: Int
    ) {
        remoteShelf = page.entries
        remoteNovels = page.entries.map(\.novel)
        isShowingCachedShelf = false
        if let reported = page.reportedCount {
            shelfGroupCounts[classID] = reported
        } else {
            shelfGroupCounts[classID] = page.entries.count
        }
        cacheShelf(page.entries, classID: classID)
    }

    // MARK: - Local cache
    //
    // The shelf is cached per group so opening 我的书架 shows the last known contents
    // immediately, then refreshes — the same order the Android app uses. A cache is
    // only ever replaced by a successful fetch: a failed refresh leaves the previous
    // contents in place rather than blanking the list.

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ShelfCache", isDirectory: true)
    }

    private func cacheURL(for classID: Int) -> URL {
        cacheDirectory.appendingPathComponent("group-\(classID).json")
    }

    private func cacheShelf(_ entries: [ShelfEntry], classID: Int) {
        let directory = cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL(for: classID), options: .atomic)

        // Counts are cached alongside so the chips are right on next launch.
        if var counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] {
            counts["\(classID)"] = shelfGroupCounts[classID]
            UserDefaults.standard.set(counts, forKey: countsKey)
        } else {
            UserDefaults.standard.set(["\(classID)": shelfGroupCounts[classID] ?? 0], forKey: countsKey)
        }
    }

    private var countsKey: String { "wenku8.shelfCounts" }

    /// True when the group currently shown came from the cache and has not been
    /// replaced by a fresh fetch yet.
    @Published private(set) var isShowingCachedShelf = false

    /// Loads a cached group. Returns false when nothing was cached.
    @discardableResult
    func loadCachedShelf(classID: Int) -> Bool {
        guard let data = try? Data(contentsOf: cacheURL(for: classID)),
              let entries = try? JSONDecoder().decode([ShelfEntry].self, from: data) else {
            return false
        }
        remoteShelf = entries
        remoteNovels = entries.map(\.novel)
        isShowingCachedShelf = true
        return true
    }

    /// Restores what was cached from a previous launch, for the whole app to show
    /// before the first network call returns.
    func restoreCachedShelf() {
        if let counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] {
            shelfGroupCounts = Dictionary(
                uniqueKeysWithValues: counts.compactMap { key, value in
                    Int(key).map { ($0, value) }
                }
            )
        }
        loadCachedShelf(classID: selectedShelfClass)
    }

    /// Two-way sync between the device shelf and the account's.
    ///
    /// The rule that matters (and the reason this is not just "download the server's
    /// list"): a book the reader saved locally but which the account does not have is
    /// **uploaded, never discarded**. Signing in, or adding a few books before
    /// signing in, must not silently delete them.
    ///
    /// - Parameter localIDs: the device's shelf, read once by the caller.
    /// Chapter the device has recorded for each book, used to tell a stale row from a
    /// current one. Supplied by the caller, which owns the reading history.
    var localChapterIDs: [Int: Int] = [:]

    func syncWithLocalShelf(_ localIDs: [Int]) async {
        guard isSignedIn, !isSyncingShelf else { return }
        isSyncingShelf = true
        defer { isSyncingShelf = false }

        // Show the cached group immediately, then replace it with the server's copy.
        loadCachedShelf(classID: selectedShelfClass)

        let page = try? await service.remoteShelfPage(classID: selectedShelfClass)
        if let page {
            apply(page: page, classID: selectedShelfClass)
        }
        let shelf = page?.entries ?? remoteShelf

        let cloudIDs = shelf.map(\.novel.id)
        let plan = ShelfSyncPlanner.plan(local: localIDs, cloud: cloudIDs)

        // Books on both sides whose recorded chapter has moved: the device is showing
        // an older catalogue than the account knows about. Android calls this the stale
        // set, and it is what makes a refresh cheap — only the changed books are
        // refetched rather than the whole shelf.
        let snapshots = shelf.map { entry in
            ShelfSyncPlanner.ShelfSnapshot(
                id: entry.novel.id,
                localLatestChapterID: localChapterIDs[entry.novel.id],
                cloudLatestChapterID: entry.latestChapter?.id
            )
        }
        let stale = ShelfSyncPlanner.staleNovels(cloud: snapshots, local: localIDs)
        if !stale.isEmpty {
            for aid in stale {
                _ = try? await service.volumes(aid: aid)
            }
        }

        guard !plan.toUploadRemotely.isEmpty else { return }

        // Upload the local-only books one at a time; a failure on one must not stop
        // the rest, and the book stays on the device regardless.
        for aid in plan.toUploadRemotely {
            _ = try? await service.addToBookcase(aid: aid)
        }

        // Re-read so the shelf reflects what the account now holds.
        if let refreshed = try? await service.remoteShelfPage(classID: selectedShelfClass) {
            apply(page: refreshed, classID: selectedShelfClass)
        }
    }

    /// Switches the visible group and reloads it.
    func selectShelfGroup(_ classID: Int) async {
        guard classID != selectedShelfClass else { return }
        selectedShelfClass = classID
        // Cached contents first so switching feels instant; the fetch replaces them.
        remoteShelf = []
        remoteNovels = []
        loadCachedShelf(classID: classID)
        await syncShelf()
    }

    /// Adds the book to the site's shelf, optionally into a group.
    ///
    /// Returns a user-facing status string.
    func addToRemoteShelf(_ novel: NovelSummary, classID: Int? = nil) async -> String {
        guard isSignedIn else { return "请先登录文库账号" }
        guard !pendingAdds.contains(novel.id) else { return "正在添加…" }
        pendingAdds.insert(novel.id)
        defer { pendingAdds.remove(novel.id) }
        do {
            let result = try await service.addToBookcase(aid: novel.id, classID: classID)
            await syncWithLocalShelf([])
            let groupName = classID.flatMap { id in
                shelfGroups.first { $0.classID == id }?.title
            }
            switch result {
            case .succeeded:
                return groupName.map { "已加入\($0)" } ?? "已加入文库云端书架"
            case .alreadyPresent: return "这本书已在云端书架中"
            case .shelfFull: return "云端书架已满"
            case .notPresent, .notSignedIn: return "请先登录文库账号"
            case .failed(let message): return message
            }
        } catch Wenku8Error.needLogin {
            return "登录已过期，请重新登录"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "添加失败，请稍后重试"
        }
    }

    func removeFromRemoteShelf(_ novelID: Int) async -> String {
        guard isSignedIn else { return "请先登录文库账号" }
        do {
            _ = try await service.removeFromBookcase(aid: novelID)
            remoteNovels.removeAll { $0.id == novelID }
            await syncShelf()
            return "已从云端书架移除"
        } catch Wenku8Error.needLogin {
            return "登录已过期，请重新登录"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "移除失败，请稍后重试"
        }
    }

    func isOnRemoteShelf(_ novelID: Int) -> Bool {
        remoteNovels.contains { $0.id == novelID }
    }

    private func setUserName(_ name: String?) {
        userName = name
        if let name {
            defaults.set(name, forKey: nameKey)
        } else {
            defaults.removeObject(forKey: nameKey)
        }
    }
}
