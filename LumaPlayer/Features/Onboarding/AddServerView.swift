import SwiftUI

/// 添加服务器表单(地址 + 用户名 + 密码,保存即探测并登录)。
///
/// 两种使用场景:
/// - 首次启动的引导页(无取消按钮 —— 没有可返回的地方);
/// - 设置窗口「服务器」标签页里的 +(sheet,有取消按钮)。
struct AddServerView: View {
    @State private var viewModel: AddServerViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    /// 进行中的连接。取消 = 连请求一起取消,不在关掉的表单背后偷偷把服务器加上
    @State private var saveTask: Task<Void, Never>?

    private let showsCancelButton: Bool
    private let container: AppContainer
    /// 百度网盘那一页。⛔ 入口放在这里而不是主窗口:首次启动时还没有任何
    /// Emby 服务器,而百度源与服务器无关 —— 不挂一个入口的话,
    /// 「只想播网盘里的片子」的人根本进不来。
    @State private var showsBaiduPan = false

    private enum Field: Hashable {
        case address, displayName, username, password
    }

    @MainActor
    init(container: AppContainer, showsCancelButton: Bool = false) {
        self.showsCancelButton = showsCancelButton
        self.container = container
        _viewModel = State(initialValue: AddServerViewModel(container: container))
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "server.rack",
                title: "添加 Emby 服务器",
                subtitle: "连接成功后会记住登录信息,令牌失效时自动重新登录。"
            )

            Form {
                Section {
                    TextField(
                        "地址",
                        text: $viewModel.address,
                        prompt: Text("https://emby.example.com")
                    )
                    .textContentType(.URL)
                    .focused($focusedField, equals: .address)
                    .onSubmit { focusedField = .username }
                    TextField(
                        "名称",
                        text: $viewModel.displayName,
                        prompt: Text("可选,默认使用服务器名称")
                    )
                    .focused($focusedField, equals: .displayName)
                } header: {
                    Text("服务器")
                } footer: {
                    if viewModel.showsInsecureWarning {
                        OnboardingNotice(
                            text: "该地址使用未加密的 HTTP,密码将以明文发送。",
                            style: .warning
                        )
                    } else {
                        Text("可省略 https:// 与端口;局域网地址连不上 HTTPS 时会自动尝试 HTTP。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("用户名", text: $viewModel.username)
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                    SecureField("密码", text: $viewModel.password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .onSubmit(submit)
                    Toggle("记住密码", isOn: $viewModel.rememberPassword)
                        .help("登录失效时自动重新登录。密码保存在本机沙盒容器的凭据文件里,未加密。")
                } header: {
                    Text("账户")
                } footer: {
                    if let message = viewModel.errorMessage {
                        OnboardingNotice(text: message, style: .error)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(viewModel.isSaving)
            .onChange(of: [viewModel.address, viewModel.username, viewModel.password]) { _, _ in
                viewModel.errorMessage = nil
            }

            OnboardingActionBar(
                primaryTitle: "连接",
                busyTitle: "正在连接服务器…",
                isBusy: viewModel.isSaving,
                canSubmit: viewModel.canSave,
                onCancel: showsCancelButton ? { cancel() } : nil,
                onSubmit: submit
            )

            Button("改用百度网盘…") { showsBaiduPan = true }
                .font(.callout)
                .padding(.bottom, Metrics.spacingL)
                .help("不连 Emby 服务器,直接播百度网盘「我的应用数据」目录里的视频")
        }
        .sheet(isPresented: $showsBaiduPan) {
            BaiduPanSourceView(container: container)
        }
        .frame(width: Metrics.onboardingFormWidth)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focusedField = .address }
    }

    private func submit() {
        guard viewModel.canSave else { return }
        saveTask = Task {
            if await viewModel.save(), !Task.isCancelled {
                dismiss()
            }
        }
    }

    private func cancel() {
        saveTask?.cancel()
        dismiss()
    }
}
