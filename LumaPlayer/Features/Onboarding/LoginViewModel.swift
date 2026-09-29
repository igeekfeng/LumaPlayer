import Foundation
import Observation

/// 已有服务器的重新登录(token 缺失或 401 之后)。
///
/// 用户名预填上次成功的那个(ARCHITECTURE.md 7.3「保留地址和用户名」);
/// 密码不预填 —— 它从不落盘(8.1)。
@MainActor
@Observable
final class LoginViewModel {
    var username: String
    var password = ""
    var errorMessage: String?
    private(set) var isSubmitting = false

    private let container: AppContainer
    private let server: ServerProfile

    init(container: AppContainer, server: ServerProfile) {
        self.container = container
        self.server = server
        self.username = server.username ?? ""
    }

    /// 只读展示用:显示名与地址。View 不据此拼 URL(ARCHITECTURE.md 6.3)。
    var serverDisplayName: String {
        server.displayName
    }

    var serverAddress: String {
        server.baseURL.absoluteString
    }

    /// 该服务器最终是不是 http 连接(含探测阶段的局域网回退)。
    /// 是则必须明确标注未加密(API_CONTRACT.md 1.4、ARCHITECTURE.md 8.2)。
    var isUnencrypted: Bool {
        server.baseURL.scheme == "http"
    }

    var canSubmit: Bool {
        !isSubmitting && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 登录成功返回 true(视图随即关闭)。
    func submit() async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await container.login(to: server, username: username, password: password)
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
