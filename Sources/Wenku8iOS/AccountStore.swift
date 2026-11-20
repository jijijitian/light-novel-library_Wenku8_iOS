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
            // A remembered name is only a claim. Cold start settles it, so a session that
            // expired while the app was closed is noticed now rather than at the first
            // failed shelf call.
            Task { await checkSessionOnLaunch() }
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

    /// Fetches a fresh captcha for the website login form.
    func loginCaptcha() async throws -> Data {
        try await service.loginCaptcha()
    }

    /// Signs in to the website with a captcha the reader read off the image.
    ///
    /// Used when the relay is off: it is the only way into the desktop pages now that their
    /// form is captcha-guarded.
    func signInToSite(username: String, password: String, captcha: String) async -> Bool {
        guard !isSigningIn else { return false }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }
        do {
            let session = try await service.signInToSite(
                username: username,
                password: password,
                captcha: captcha
            )
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

    /// True when a cold-start check found the remembered session gone.
    ///
    /// The root view drives a prompt from this; the app is already signed out by the time
    /// it is set, so dismissing the prompt leaves a consistent state.
    @Published private(set) var sessionExpiredNotice = false

    func dismissSessionExpiredNotice() {
        sessionExpiredNotice = false
    }

    /// Settles the remembered login once, at launch.
    ///
    /// Signing out is only ever the result of a definite answer: an unreachable site leaves
    /// the state untouched, so opening the app without a network does not log the reader out.
    func checkSessionOnLaunch() async {
        // Nothing remembered means nothing to settle: a signed-out launch never touches the
        // network for this.
        guard userName != nil else {
            sessionExpiredNotice = false
            return
        }

        switch await service.sessionState() {
        case .signedIn(let name):
            // The relay can confirm a session without telling us the name; keep the one we
            // already have rather than blanking it.
            if !name.isEmpty { setUserName(name) }
            sessionExpiredNotice = false
        case .signedOut:
            service.signOut()
            setUserName(nil)
            // Keep what the shelf showed. The books are still known and still on the
            // account; only the session is gone, and a reader who cannot sign in right now
            // should still see their shelf rather than an empty page.
            restoreCachedShelf()
            sessionExpiredNotice = true
        case .unknown:
            // Could not ask. Keep whatever was known rather than guess.
            break
        }
    }

    /// What a post-switch login check concluded.
    enum SessionCheck {
        /// Nobody was signed in, so there was nothing to lose.
        case notSignedIn
        /// The session still works, for this account.
        case valid(String)
        /// The session is gone. The app no longer claims it; the reader signs in again.
        case expired
    }

    /// Re-checks the login after the data source changed.
    ///
    /// Switching the site domain or turning the relay on or off changes where requests go:
    /// the website session lives in a cookie scoped to one domain, and the relay
    /// authenticates separately. Either change can strand the app holding a name with no
    /// session behind it, which shows up later as every shelf call failing.
    ///
    /// The check runs once, immediately after the switch. It does not try to sign in again:
    /// no password is kept, in memory or on disk, so the only honest outcome is to report
    /// that a login is needed and let the reader supply one.
    func verifySessionAfterSourceChange() async -> SessionCheck {
        // Signed out already: there is no session to verify, and the app must not go
        // probing a source on behalf of nobody. Every switch is silent in that state.
        guard userName != nil else { return .notSignedIn }

        // Which session to ask is decided by the switch itself, and `sessionState()`
        // answers it: relay enabled means the relay, relay disabled means the site now
        // selected.
        switch await service.sessionState() {
        case .signedIn(let name):
            if !name.isEmpty { setUserName(name) }
            return .valid(userName ?? name)
        case .unknown:
            // Could not ask. Leave the state alone rather than sign the reader out on a
            // failed request.
            return .valid(userName ?? "")
        case .signedOut:
            // Drop the name rather than leave the app claiming a session it does not have,
            // but keep the shelf it described: the books did not vanish with the session.
            setUserName(nil)
            restoreCachedShelf()
            return .expired
        }
    }

    /// Saves the shelf's cover images so its rows stop fetching them every time.
    ///
    /// The shelf is a list of small covers, and each one used to be requested from the
    /// network on every visit. A bounded pass per sync fills the cache in; rows fall back to
    /// the remote image only until their turn comes.
    func cacheShelfCovers(limit: Int = 16) async {
        // Covers come from the public image host, so a signed-out shelf can cache them too.
        var saved = 0
        for entry in remoteShelf where saved < limit {
            let aid = entry.novel.id
            if await OfflineStore.shared.storedCoverURL(for: aid) != nil { continue }
            if await service.cacheCover(aid: aid, coverURL: entry.novel.coverURL) {
                saved += 1
            }
        }
    }

    /// Refreshes what the shelf rows show: title, author and cover.
    ///
    /// A book's page is public, so this works without a session — an expired login should
    /// not freeze the information on the shelf. A few books per refresh, rotating through
    /// the shelf, keeps a pull from turning into thirty requests; repeated pulls walk the
    /// whole list.
    func refreshShelfBookInfo(limit: Int = 4) async {
        guard !remoteShelf.isEmpty else { return }
        var updated = remoteShelf
        var touched = 0
        var visited = 0
        while visited < updated.count, touched < limit {
            let index = (shelfRefreshCursor + visited) % updated.count
            visited += 1
            let aid = updated[index].novel.id
            guard let detail = await service.refreshBookInfo(aid: aid) else { continue }
            if updated[index].novel.title != detail.title
                || updated[index].novel.author != (detail.author.isEmpty ? nil : detail.author) {
                updated[index].novel.title = detail.title
                updated[index].novel.author = detail.author.isEmpty ? nil : detail.author
                touched += 1
            }
        }
        shelfRefreshCursor = (shelfRefreshCursor + visited) % max(updated.count, 1)
        if touched > 0 {
            remoteShelf = updated
            remoteNovels = updated.map(\.novel)
        }
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

    /// Where the next shelf-info refresh starts, so repeated pulls cover the whole shelf.
    private var shelfRefreshCursor = 0

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

    /// Caches metadata for every book on the shelf, and drops metadata for books that
    /// have left it.
    ///
    /// Shelf books should open instantly and survive an outage even when their chapters
    /// were never downloaded, so their detail records are stored. The same pass removes
    /// metadata for books that are on neither the shelf nor the device — otherwise the
    /// cache would grow forever with books the reader has thrown away.
    ///
    /// - Parameter localIDs: books saved on the device, which keep their metadata.
    func syncShelfMetadata(localIDs: [Int]) async {
        guard isSignedIn else { return }
        let shelfIDs = Set(remoteShelf.map(\.novel.id))
        // Never touch a book that has chapters: those are downloads, not metadata.
        let downloaded = await OfflineStore.shared.entries()
            .filter { !$0.chapterIDs.isEmpty }
            .map(\.novelID)
        let keep = shelfIDs.union(localIDs).union(downloaded)

        for entry in await OfflineStore.shared.entries() {
            guard entry.chapterIDs.isEmpty else { continue }
            if !keep.contains(entry.novelID) {
                await OfflineStore.shared.delete(entry.novelID)
            }
        }

        // A shelf book needs its catalogue, not just its blurb: the detail page has
        // nothing to list without it. Books cached before catalogues were stored are
        // picked up here too, so an existing shelf repairs itself.
        let entries = await OfflineStore.shared.entries()
        var needsCatalogue: [Int] = []
        for aid in shelfIDs {
            guard let entry = entries.first(where: { $0.novelID == aid }) else {
                needsCatalogue.append(aid)
                continue
            }
            // A book is only complete when it has a catalogue and a cover on disk; a
            // missing cover means the page downloads it on every visit.
            if (entry.volumes?.isEmpty ?? true) || entry.coverFile == nil {
                needsCatalogue.append(aid)
            }
        }

        // A handful per sync keeps the relay's throttle from being starved by this.
        for aid in needsCatalogue.prefix(8) {
            await service.cacheDetailFully(aid: aid)
        }
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
        guard isSignedIn else { return }
        // A pull during a running sync used to be dropped outright, so the gesture did
        // nothing. Wait for that one to finish instead, bounded so a stuck sync cannot
        // hang the refresh forever.
        var waited = 0
        while isSyncingShelf && waited < 80 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard !isSyncingShelf else { return }
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
