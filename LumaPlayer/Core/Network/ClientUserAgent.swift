import Foundation

/// 播放链路与 API 请求的 `User-Agent`。
///
/// - 用户没填:API 走系统默认 UA(以 `LumaPlayer/{版本}` 开头);mpv 显式设成 `LumaPlayer/{版本}`
///   (它默认是 `libmpv`,与 `Client="LumaPlayer"` 不一致)。
/// - 填了自定义值:API、图片、mpv 全部用它,逐请求读取、改完即时生效。
///
/// 用途:部分服务器网关按 UA 只放行白名单播放器(issue #2)。⛔ 默认不冒充其它客户端。
enum ClientUserAgent {
    /// 设置页 `@AppStorage` 与这里共用的 UserDefaults key
    static let customKey = "network.customUserAgent"

    /// 已净化;没填返回 nil
    static var custom: String? {
        sanitized(UserDefaults.standard.string(forKey: customKey) ?? "")
    }

    /// 自定义优先,否则 `LumaPlayer/{版本}`
    static var value: String {
        custom ?? format(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// 剔除控制字符:`URLRequest.setValue` 遇到带控制字符的值会静默丢掉整条头;
    /// 粘贴的 UA 常带尾随换行,所以剔除而不是整值作废。空串返回 nil。
    static func sanitized(_ raw: String) -> String? {
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 取不到版本时不带版本段,不编一个。
    static func format(version: String?) -> String {
        guard let version, !version.isEmpty,
              version.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\"" })
        else { return EmbyRequestBuilder.clientName }
        return "\(EmbyRequestBuilder.clientName)/\(version)"
    }
}
