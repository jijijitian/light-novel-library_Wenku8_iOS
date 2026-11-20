import SwiftUI
import Wenku8Core

struct LoginView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var localError: String?
    @State private var showRegister = false
    /// Whether the website's captcha is required: only when the relay is off, since the
    /// relay has none and the app reads from whichever source is enabled.
    private var needsCaptcha: Bool { !RelayCredentialStore.shared.isEnabled }
    @State private var captcha = ""
    @State private var captchaImage: Data?
    @State private var isLoadingCaptcha = false
    @FocusState private var focus: Field?

    private enum Field { case username, password, captcha }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && (!needsCaptcha || !captcha.trimmingCharacters(in: .whitespaces).isEmpty)
            && !account.isSigningIn
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    VStack(spacing: 14) {
                        field(
                            title: "账号",
                            systemImage: "person.crop.circle",
                            text: $username,
                            prompt: "用户名或邮箱",
                            isSecure: false
                        )
                        .focused($focus, equals: .username)
                        // Deliberately no `.textContentType(.username)`: marking this
                        // as a credential field makes iOS offer AutoFill and swap in
                        // the password keyboard, which suppresses third-party input
                        // methods — the account field then cannot be typed into with
                        // a Chinese IME. The keyboard type is left at the default for
                        // the same reason: `.asciiCapable` would pin it to English.
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focus = .password }

                        field(
                            title: "密码",
                            systemImage: "lock",
                            text: $password,
                            prompt: "文库密码",
                            isSecure: !showPassword
                        )
                        .focused($focus, equals: .password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { submit() }

                        Toggle(isOn: $showPassword) {
                            Label("显示密码", systemImage: showPassword ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .tint(AppTheme.accent)

                        if needsCaptcha {
                            Divider()
                            HStack(spacing: 12) {
                                TextField("验证码", text: $captcha)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .focused($focus, equals: .captcha)
                                captchaImageButton
                            }
                        }
                    }
                    .padding(18)
                    .glassCard(cornerRadius: 24)

                    if let message = localError ?? account.lastError {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(cornerRadius: 14)
                    }

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if account.isSigningIn {
                                ProgressView().controlSize(.small)
                            }
                            Text(account.isSigningIn ? "正在登录…" : "登录")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .prominentGlassButtonShape()
                    .tint(AppTheme.accent)
                    .disabled(!canSubmit)

                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background { AppBackground() }
            .navigationTitle("登录文库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            // The register page follows the selected mirror, like every other web link.
            .sheet(isPresented: $showRegister) {
                WebSheet(url: SiteDomain.current.webURL("/register.php"))
            }
            .onAppear { focus = .username }
            .task { await loadCaptcha() }
        }
    }

    /// The captcha image, tappable to fetch another.
    @ViewBuilder
    private var captchaImageButton: some View {
        Button {
            Task { await loadCaptcha() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                if let captchaImage, let image = UIImage(data: captchaImage) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(4)
                } else if isLoadingCaptcha {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 108, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("刷新验证码")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
            Text("登录后可同步云端书架")
                .font(.title3.weight(.bold))
            Text("账号密码只会直接提交给轻小说文库网站，App 不保存密码，仅在系统 Cookie 中保留登录状态。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有账号？可以在文库网页版免费注册。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showRegister = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                    Text("注册新账号")
                }
                .frame(maxWidth: .infinity)
            }
            .secondaryGlassButtonShape()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func field(
        title: String,
        systemImage: String,
        text: Binding<String>,
        prompt: String,
        isSecure: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if isSecure {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .textFieldStyle(.plain)
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: 12)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        localError = nil
        Task {
            let ok: Bool
            if needsCaptcha {
                ok = await account.signInToSite(
                    username: username,
                    password: password,
                    captcha: captcha
                )
            } else {
                ok = await account.signIn(username: username, password: password)
            }
            if ok {
                dismiss()
            } else {
                localError = account.lastError ?? "登录失败"
                password = ""
                // A captcha is single-use, so a failed attempt needs a new one.
                if needsCaptcha { captcha = ""; await loadCaptcha() }
            }
        }
    }

    /// Loads a captcha image, replacing whatever was shown.
    private func loadCaptcha() async {
        guard needsCaptcha else { return }
        isLoadingCaptcha = true
        defer { isLoadingCaptcha = false }
        do {
            captchaImage = try await account.loginCaptcha()
        } catch {
            captchaImage = nil
            localError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
