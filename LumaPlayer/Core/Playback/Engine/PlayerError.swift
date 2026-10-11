import Foundation

/// 播放引擎错误(**与内核无关**)。
///
/// 内核自己的错误类型(如 Erika 的 `ErikaError`)在 `Core/Erika/` 的适配器里
/// 转成这个类型,上层只认它。`message` 面向诊断与用户文案,
/// ⛔ 不得包含完整播放 URL(可能带 `api_key`,见 API_CONTRACT.md 第 6 节)。
struct PlayerError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }

    /// 让 `"\(error)"` 直接得到人读消息,而不是结构体反射的默认输出
    /// (调用方大量用字符串插值拼用户文案)。
    var description: String { message }
}
