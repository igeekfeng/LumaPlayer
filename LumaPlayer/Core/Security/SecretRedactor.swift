import Foundation

/// 凭据脱敏(PITFALLS.md Q9)。写进日志、警告框、诊断导出的文本都必须先过这里,
/// ⛔ 不在调用方手动删字段。
enum SecretRedactor {
    static let placeholder = "<redacted>"

    /// 小写比较
    private static let sensitiveKeys = [
        "api_key", "apikey", "api-key",
        "x-emby-token", "x-mediabrowser-token",
        "accesstoken", "access_token", "token",
        "password", "pw",
        "authorization",
    ]

    /// 替换 `api_key=…`、`X-Emby-Token: …`、整行 `Authorization: …` 等;只按键名匹配,不误删正常参数。
    static func redacted(_ text: String) -> String {
        var result = text
        // Authorization 的值自带空格与逗号,整段替换到行尾
        result = replacing(
            pattern: #"(?im)(authorization\s*[:=]\s*)(.*)$"#,
            template: "$1" + placeholder,
            in: result
        )
        for key in sensitiveKeys where key != "authorization" {
            // key=value / key:value / JSON 的 "Key":"value";值遇到 & 空格 逗号 引号即止
            result = replacing(
                pattern: #"(?i)(\#(key)["']?\s*[:=]\s*)(["']?)([^&\s"',]+)\2"#,
                template: "$1$2" + placeholder + "$2",
                in: result
            )
        }
        return result
    }

    /// 去掉 user/password 与敏感查询参数值,保留路径与其余参数供诊断。
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
