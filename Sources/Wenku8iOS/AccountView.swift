import SwiftUI
import Wenku8Core

/// The signed-in account: who it is, what it holds, and how to leave it.
struct AccountView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var showLogin = false

    /// A refresh against a warm connection can finish before the indicator is seen, which reads as
    /// the gesture being ignored. The same floor the home screen uses: a wait, not a delay.
    private static let minimumRefreshDuration: Duration = .milliseconds(1200)

    var body: some View {
        // The account's own details are short enough to fit the screen, and a scroll view that
        // fits has no range for `.refreshable` to arm its pull against. Sizing the content to the
        // viewport gives it one.
        GeometryReader { proxy in
        ScrollView {
            VStack(spacing: 14) {
            if account.isSignedIn {
                Panel {
                    HStack(spacing: 12) {
                        AccountAvatar(url: account.profile?.avatarURL, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.userName ?? "已登录")
                                .font(.headline)
                            Text("文库账号")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if account.isSyncingShelf {
                            ProgressView().controlSize(.small)
                        }
                    }
                    // Inset like a `PanelRow`: without it the avatar met the panel's edge.
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                // What the site prints on the account's own page. The shelf total belongs to
                // the shelf, not here.
                if let profile = account.profile {
                    Panel(title: "用户信息") {
                        ForEach(profile.fields) { field in
                            fieldRow(field)
                        }
                    }
                } else if account.isLoadingProfile {
                    Panel {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在载入账号信息…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }

                Panel {
                    Button(role: .destructive) {
                        account.signOut()
                    } label: {
                        PanelRow {
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            } else {
                Panel {
                    Button {
                        showLogin = true
                    } label: {
                        PanelRow {
                            Label("登录文库账号", systemImage: "person.badge.key")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("登录后可把小说加入文库云端书架，并在多台设备间同步。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(minHeight: proxy.size.height, alignment: .top)
        }
        .scrollBounceBehavior(.always)
        .background { AppBackground() }
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        // A pull re-reads the profile; the identity comes from the stored copy, so the page is
        // never blank while the request is in flight.
        .refreshable { await refresh() }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .task {
            account.loadStoredProfile()
            await account.refreshProfile()
        }
        }
    }

    /// Re-reads the account's details.
    ///
    /// The work runs in an unstructured task for the reason the home screen's refresh does:
    /// `.refreshable` runs its closure in a task SwiftUI cancels as soon as the content is rebuilt.
    private func refresh() async {
        let started = ContinuousClock.now
        await Task { await account.refreshProfile() }.value
        let deadline = started + Self.minimumRefreshDuration
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// One label and its value.
    ///
    /// A long value gets its own line under the label; squeezing a referral-style string into a
    /// trailing column broke it mid-word.
    @ViewBuilder
    private func fieldRow(_ field: UserProfile.Field) -> some View {
        if field.value.count > 24 {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                Text(field.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            PanelRow {
                Text(field.label)
                Spacer(minLength: 0)
                Text(field.value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// The account's picture, falling back to the person glyph when the site has none.
///
/// The site serves a generic silhouette as `noavatar.jpg` for accounts that never set one, so a
/// URL alone does not mean there is a picture worth showing.
struct AccountAvatar: View {
    var url: URL?
    var size: CGFloat

    private var showsPicture: Bool {
        guard let url else { return false }
        return !url.lastPathComponent.lowercased().contains("noavatar")
    }

    var body: some View {
        Group {
            if showsPicture, let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(AppTheme.accent.opacity(0.16))
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size * 0.48))
                .foregroundStyle(AppTheme.accent)
        }
    }
}
