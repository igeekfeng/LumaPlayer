import Foundation
import mpv

/// libmpv 错误映射(MPV_INTEGRATION.md §9,枚举 case 是契约,不得增删)。
///
/// 映射规则:
/// - C API 返回值 < 0 → `commandFailed`(`mpv_error_string(code)` 取消息);
/// - `MPV_EVENT_END_FILE` 且 reason == error(4) → `loadFailed`;
/// - 渲染上下文创建失败 → `renderContextFailed`;
/// - `destroyed` 之后任何方法调用 → `instanceDestroyed`(§8 规则 2,不得静默)。
///
/// ⛔ 错误消息里不得包含完整播放 URL(含 `api_key` 时)——
/// 本类型不拼 URL,但构造方传入的 reason/message 必须遵守(经
/// `SecretRedactor` 统一处理,见 API_CONTRACT.md 第 6 节)。
enum MPVError: Error, Equatable, Sendable {
    case instanceDestroyed
    case commandFailed(code: Int32, message: String)
    case renderContextFailed(String)
    case loadFailed(reason: String)
}

/// 把 mpv C API 错误码转成 `MPVError.commandFailed`(§9:必须检查每个返回值)。
/// - Parameter code: mpv 返回的错误码(< 0 视为失败)
/// - Parameter what: 上下文描述(不含 URL / 密钥),便于诊断
func mpvFailure(_ code: Int32, _ what: String) -> MPVError {
    let message = String(cString: mpv_error_string(code))
    return .commandFailed(code: code, message: "\(what): \(message)")
}
