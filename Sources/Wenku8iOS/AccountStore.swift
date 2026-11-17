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
    @Published private(set) var pendingAdds = Set<Int>()

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
        lastError = nil
    }

    /// Pulls the site's bookcase so the app can show it next to the local shelf.
    func syncShelf() async {
        guard isSignedIn, !isSyncingShelf else { return }
        isSyncingShelf = true
        defer { isSyncingShelf = false }
        if let novels = try? await service.remoteBookcase() {
            remoteNovels = novels
        }
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
