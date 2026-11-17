import SwiftUI
import Wenku8Core

struct LoginView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var showWeb = false
    @State private var localError: String?
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
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
                        .textContentType(.username)
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

                    Button {
                        showWeb = true
                    } label: {
                        Label("在网页版登录", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryGlassButtonShape()

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
            .sheet(isPresented: $showWeb) {
                WebSheet(url: URL(string: "https://www.wenku8.net/login.php"))
            }
            .onAppear { focus = .username }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有账号？可以在文库网页版免费注册。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "https://www.wenku8.net/register.php")!) {
                Text("前往注册")
                    .font(.caption.weight(.medium))
            }
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
            let ok = await account.signIn(username: username, password: password)
            if ok {
                dismiss()
            } else {
                localError = account.lastError ?? "登录失败"
                password = ""
            }
        }
    }
}
