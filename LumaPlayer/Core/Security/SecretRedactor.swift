import Foundation

/// 凭据脱敏(CLAUDE.md「安全与隐私」;docs/PITFALLS.md Q9)。
///
/// 播放 URL 可能带认证信息(认证头 / 可能的 `api_key` 退路),
/// 任何写进日志、警告框或未来诊断导出的文本都必须先过这里。
/// ⛔ 不要在调用方「记得」手动删字段 —— 人总会忘,统一走本类型。
enum SecretRedactor {
    /// 替换后的占位串
    static let placeholder = "<redacted>"

    /// 需要脱敏的键名(小写比较)。范围按 CLAUDE.md「安全与隐私」:
    /// `api_key` / Token / Authorization / 密码字段。
    private static let sensitiveKeys = [
        "api_key", "apikey", "api-key",
        "x-emby-token", "x-mediabrowser-token",
        "accesstoken", "access_token", "token",
        "password", "pw",
        "authorization",
    ]

    /// 对任意文本脱敏:查询串里的 `api_key=…`、报头/表单里的
    /// `X-Emby-Token: …`、整行 `Authorization: …` 都会被替换。
    ///
    /// 匹配不到就原样返回,不会因为「看起来像凭据」而误删正常参数。
    static func redacted(_ text: String) -> String {
        var result = text
        // Authorization 的值自带空格与逗号(Emby 的 `Emby UserId="..", Client=".."`),
        // 按「值取到行尾」整段替换,不能只替换到第一个分隔符。
        result = replacing(
            pattern: #"(?im)(authorization\s*[:=]\s*)(.*)$"#,
            template: "$1" + placeholder,
            in: result
        )
        for key in sensitiveKeys where key != "authorization" {
            // key=value / key:value(JSON 里是 "Key":"value",键名后面可能
            // 先有一个闭合引号);值可选地被引号包住,遇到 & 空格 逗号 引号即止
            result = replacing(
                pattern: #"(?i)(\#(key)["']?\s*[:=]\s*)(["']?)([^&\s"',]+)\2"#,
                template: "$1$2" + placeholder + "$2",
                in: result
            )
        }
        return result
    }

    /// URL 的安全描述:去掉 user/password 片段,并把敏感查询参数的值替换掉。
    ///
    /// 用于「日志里想说清播的是什么、但不能泄露凭据」的场景 ——
    /// 路径与非敏感参数保留,诊断时才看得出问题出在哪。
    static func redactedDescription(of url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return redacted(url.absoluteString)
        }
        components.user = nil
        components.password = nil
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                isSensitive(item.name)
                    ? URLQueryItem(name: item.name, value: placeholder)
                    : item
            }
        }
        return components.string ?? redacted(url.absoluteString)
    }

    static func isSensitive(_ name: String) -> Bool {
        sensitiveKeys.contains(name.lowercased())
    }

    // MARK: - 内部

    private static func replacing(pattern: String, template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: template)
    }
}
