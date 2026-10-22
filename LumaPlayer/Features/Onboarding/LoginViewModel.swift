import Foundation
import Observation

/// 已有服务器的重新登录(token 缺失或 401 之后)。用户名预填上次成功的那个,
/// 记住密码默认不勾 —— 静默重登既然没成立,是否再记一次交给用户。
@MainActor
@Observable
final class LoginViewModel {
    var username: String
    var password = ""
    var rememberPassword = false
    var errorMessage: String?
    private(set) var isSubmitting = false

    private let container: AppContainer
    private let server: ServerProfile

    init(container: AppContainer, server: ServerProfile) {
        self.container = container
        self.server = server
        self.username = server.username ?? ""
    }

    /// 只读展示用:显示名与地址。View 不据此拼 URL(CLAUDE.md「架构主线」)。
    var serverDisplayName: String {
        server.displayName
    }

    var serverAddress: String {
        server.baseURL.absoluteString
    }

    /// http 连接(含局域网回退)必须标注未加密(API_CONTRACT.md 1.4、CLAUDE.md「安全与隐私」)。
    var isUnencrypted: Bool {
        server.baseURL.scheme == "http"
    }

    var canSubmit: Bool {
        !isSubmitting && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await container.login(to: server, username: username, password: password, rememberPassword: rememberPassword)
            return true
        } catch let error as ServerLoginError {
            errorMessage = error.userMessage
            return false
        } catch let error as EmbyAPIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "登录失败:\(error.localizedDescription)"
            return false
        }
    }
}
