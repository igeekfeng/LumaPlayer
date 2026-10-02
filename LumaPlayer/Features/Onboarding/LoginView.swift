import SwiftUI

/// 重新登录一台已存在的服务器。地址只读 —— 只补用户名与密码
/// (ARCHITECTURE.md 7.3)。
///
/// 记住了密码时 401 会先静默重新登录,走到这里说明静默登录也没成立
/// (密码在服务端改过、或没勾选记住密码)。
struct LoginView: View {
    @State private var viewModel: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var passwordFocused: Bool

    @MainActor
    init(container: AppContainer, server: ServerProfile) {
        _viewModel = State(initialValue: LoginViewModel(container: container, server: server))
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "person.badge.key",
                title: "重新登录",
                subtitle: "\(viewModel.serverDisplayName) 的登录已失效,请重新输入密码。"
            )

            Form {
                Section {
                    LabeledContent("地址") {
                        Text(viewModel.serverAddress)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    if viewModel.isUnencrypted {
                        // 局域网 http 回退后的服务器也要警告
                        // (API_CONTRACT.md 1.4、ARCHITECTURE.md 8.2)
                        OnboardingNotice(text: "未加密连接(HTTP),密码将以明文发送。", style: .warning)
                    }
                }

                Section {
                    TextField("用户名", text: $viewModel.username)
                        .textContentType(.username)
                    SecureField("密码", text: $viewModel.password)
                        .textContentType(.password)
                        .focused($passwordFocused)
                        .onSubmit(submit)
                    Toggle("记住密码", isOn: $viewModel.rememberPassword)
                        .help("登录失效时自动重新登录。密码保存在本机沙盒容器的凭据文件里,未加密。")
                } footer: {
                    if let message = viewModel.errorMessage {
                        OnboardingNotice(text: message, style: .error)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(viewModel.isSubmitting)
            .onChange(of: [viewModel.username, viewModel.password]) { _, _ in
                viewModel.errorMessage = nil
            }

            OnboardingActionBar(
                primaryTitle: "登录",
                busyTitle: "正在登录…",
                isBusy: viewModel.isSubmitting,
                canSubmit: viewModel.canSubmit,
                onCancel: { dismiss() },
                onSubmit: submit
            )
        }
        .frame(width: Metrics.onboardingFormWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { passwordFocused = true }
    }

    private func submit() {
        guard viewModel.canSubmit else { return }
        Task {
            if await viewModel.submit() {
                dismiss()
            }
        }
    }
}
