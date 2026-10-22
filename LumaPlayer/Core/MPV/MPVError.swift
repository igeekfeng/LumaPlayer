import Foundation
import mpv

/// libmpv 错误映射(MPV_INTEGRATION.md §9;case 是契约,不得增删)。
///
/// ⛔ reason / message 不得含完整播放 URL(可能带 `api_key`),构造方经 `SecretRedactor` 处理。
enum MPVError: Error, Equatable, Sendable {
    /// `destroyed` 之后的任何调用(§8 规则 2,不得静默)
    case instanceDestroyed
    /// C API 返回值 < 0
    case commandFailed(code: Int32, message: String)
    case renderContextFailed(String)
    /// `MPV_EVENT_END_FILE` 且 reason == error
    case loadFailed(reason: String)
}

/// §9:每个 C API 返回值都必须检查。
/// - Parameter what: 上下文描述(不含 URL / 密钥)
func mpvFailure(_ code: Int32, _ what: String) -> MPVError {
    let message = String(cString: mpv_error_string(code))
    return .commandFailed(code: code, message: "\(what): \(message)")
}
