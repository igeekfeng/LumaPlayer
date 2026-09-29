import SwiftUI

/// 编辑服务器(显示名 / 地址)。地址变了会先重新探测,探测不通不保存
/// (`AppContainer.editServer`)。token 不动:新地址若不认旧 token,
/// 第一次鉴权请求 401 后会清掉 token、回到登录页(密码不存,不静默重登)。
///
/// 外壳与「添加服务器」共用(`OnboardingFormHeader` / `OnboardingNotice` / `OnboardingActionBar`)。
struct ServerSettingsView: View {
    let container: AppContainer

    private let server: ServerProfile
    @State private var displayName: String
    @State private var address: String
    @State private var errorMessage: String?
    /// 地址变了要探测一次,期间禁用保存,免得连点发出多轮探测
    @State private var isSaving = false
    /// 进行中的保存。取消 = 连探测请求一起取消
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case displayName, address
    }

    @MainActor
    init(container: AppContainer, server: ServerProfile) {
        self.container = container
        self.server = server
        _displayName = State(initialValue: server.displayName)
        _address = State(initialValue: server.baseURL.absoluteString)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "server.rack",
                title: "编辑服务器",
                subtitle: "修改显示名称或服务器地址,已保存的登录令牌不受影响。"
            )

            Form {
                Section {
                    TextField(
                        "名称",
                        text: $displayName,
                        prompt: Text("留空则保持不变")
                    )
                    .focused($focusedField, equals: .displayName)
                    .onSubmit { focusedField = .address }
                    TextField(
                        "地址",
                        text: $address,
                        prompt: Text("https://emby.example.com")
                    )
                    .textContentType(.URL)
                    .focused($focusedField, equals: .address)
                    .onSubmit(submit)
                } header: {
                    Text("服务器")
                } footer: {
                    footer
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(isSaving)
            .onChange(of: address) { _, _ in errorMessage = nil }

            OnboardingActionBar(
                primaryTitle: "保存",
                busyTitle: "正在保存…",
                isBusy: isSaving,
                canSubmit: canSave,
                onCancel: cancel,
                onSubmit: submit
            )
        }
        .frame(width: Metrics.onboardingFormWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focusedField = .displayName }
    }

    /// 错误优先,其次未加密警告,最后是「行为说明」(改地址会发生什么)。
    @ViewBuilder
    private var footer: some View {
        if let errorMessage {
            OnboardingNotice(text: errorMessage, style: .error)
        } else if showsInsecureWarning {
            OnboardingNotice(text: "该地址使用未加密的 HTTP,密码将以明文发送。", style: .warning)
        } else {
            Text("修改地址会先重新连接探测;探测不通则不保存。若新地址不认已保存的令牌,需要重新登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var showsInsecureWarning: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("http://")
    }

    private var canSave: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    private func submit() {
        guard canSave else { return }
        saveTask = Task { await save() }
    }

    private func cancel() {
        saveTask?.cancel()
        dismiss()
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await container.editServer(server, displayName: resolvedDisplayName, address: address)
            if !Task.isCancelled { dismiss() }
        } catch let error as ServerURLError {
            errorMessage = error.userMessage
        } catch let error as ServerLoginError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "保存失败,请重试。"
        }
    }

    /// 名称清空视为不修改(避免保存出空名)
    private var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? server.displayName : trimmed
    }
}
