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
    /// The site's shelf groups (默认书架 + 第1…5组), so the app can present the same
    /// organisation instead of flattening everything into one list.
    @Published private(set) var shelfGroups: [DesktopParser.ShelfGroup] = []
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

        if let groups = try? await service.remoteShelfGroups(), !groups.isEmpty {
            shelfGroups = groups
            // Keep the selection valid: a group can disappear when the account has
            // fewer shelves than before.
            if !groups.contains(where: { $0.classID == selectedShelfClass }) {
                selectedShelfClass = groups.first?.classID ?? 0
            }
        }

        if let shelf = try? await service.remoteShelf(classID: selectedShelfClass) {
            remoteShelf = shelf
            remoteNovels = shelf.map(\.novel)
        }
    }

    /// Switches the visible group and reloads it.
    func selectShelfGroup(_ classID: Int) async {
        guard classID != selectedShelfClass else { return }
        selectedShelfClass = classID
        remoteShelf = []
        remoteNovels = []
        await syncShelf()
    }

    /// Adds the book to the site's shelf. Returns a user-facing status string.
    func addToRemoteShelf(_ novel: NovelSummary) async -> String {
        guard isSignedIn else { return "请先登录文库账号" }
        guard !pendingAdds.contains(novel.id) else { return "正在添加…" }
        pendingAdds.insert(novel.id)
        defer { pendingAdds.remove(novel.id) }
        do {
            let result = try await service.addToBookcase(aid: novel.id)
            await syncShelf()
            switch result {
            case .succeeded: return "已加入文库云端书架"
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
