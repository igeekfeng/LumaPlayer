import Foundation
import Observation

/// 「添加服务器」表单的状态与校验。保存 = 地址规范化 → 探测 → 登录 → 入库
/// (API_CONTRACT.md 1.4);登录失败不落库。
@MainActor
@Observable
final class AddServerViewModel {
    var address = ""
    var displayName = ""
    var username = ""
    var password = ""
    var rememberPassword = false
    var errorMessage: String?
    private(set) var isSaving = false

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    /// 用户**显式**写了 `http://`:密码明文发送,输入阶段就警告
    /// (API_CONTRACT.md 3.1、CLAUDE.md「安全与隐私」)。没写 scheme 的由探测阶段决定,
    /// 回退成 http 后由登录页再警告一次。
    var showsInsecureWarning: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("http://")
    }

    /// 地址与用户名都填了、且不在保存中(密码允许为空:Emby 支持空密码账户)。
    var canSave: Bool {
        !isSaving
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await container.addServer(
                address: address,
                displayName: displayName,
                username: username,
                password: password,
                rememberPassword: rememberPassword
            )
            return true
        } catch is CancellationError {
            return false
        } catch let error as ServerURLError {
            errorMessage = error.userMessage
            return false
        } catch let error as ServerLoginError {
            errorMessage = error.userMessage
            return false
        } catch let error as EmbyAPIError {
            errorMessage = error.userMessage
            return false
        } catch is KeychainError {
            errorMessage = AppError.credentialMigrationFailed.errorDescription
            return false
        } catch is CredentialFileError, is CredentialStoreError {
            errorMessage = "本地凭据读写失败,无法保存设备标识或登录令牌。"
            return false
        } catch is ServerRegistryError {
            errorMessage = "服务器列表保存失败,请重试。"
            return false
        } catch {
            errorMessage = "保存失败:\(error.localizedDescription)"
            return false
        }
    }
}
