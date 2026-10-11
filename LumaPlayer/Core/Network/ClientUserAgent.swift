import Foundation

/// 播放链路与 API 请求的 `User-Agent`。
///
/// - 默认(用户没填):API 请求与播放拉流都用 `LumaPlayer/{版本}`
///   (播放链路把它放进 `playbackHeaders()`,由播放内核逐请求带上)。
/// - 用户在设置里填了自定义值:API、图片、播放全部用它。
///
/// 背景(issue #2):部分服务器带网关,只放行白名单播放器,按 UA 拒绝其余客户端的拉流。
/// 做法参照 OcPlayer:全局一个选项、逐请求读取(改完即时生效)、默认不启用。
/// ⛔ 默认不冒充其它客户端;填谁的 UA 由用户自己决定并承担后果。
enum ClientUserAgent {
    /// 设置页 `@AppStorage` 与这里共用的 UserDefaults key
    static let customKey = "network.customUserAgent"

    /// 用户填的自定义 UA(已净化);没填返回 nil
    static var custom: String? {
        sanitized(UserDefaults.standard.string(forKey: customKey) ?? "")
    }

    /// 播放链路用的 UA:自定义优先,否则 `LumaPlayer/{版本}`
    static var value: String {
        custom ?? format(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// 净化用户输入。控制字符(换行、制表…)必须剔除:`URLRequest.setValue` 遇到
    /// 带控制字符的值会把**整条头**静默丢掉,用户以为生效了其实发的是默认值;
    /// 粘贴 UA 常带尾随换行,所以是剔除而不是整值作废。空串返回 nil。
    static func sanitized(_ raw: String) -> String? {
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 纯函数,便于测试。取不到版本时不带版本段,不编一个。
    static func format(version: String?) -> String {
        guard let version, !version.isEmpty,
              version.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\"" })
        else { return EmbyRequestBuilder.clientName }
        return "\(EmbyRequestBuilder.clientName)/\(version)"
    }
}
