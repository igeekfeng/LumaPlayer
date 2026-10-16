import Darwin
import Foundation

// 地址规范化 + 本地地址判定,全部是纯函数、零网络(API_CONTRACT.md 1.3)。
// 公开信息端点探测(`/emby` 前缀判定)在 `ServerConnection.probeServer`。
//
// 注意:本文件名 ServerDiscovery 指的是「手动添加服务器时的地址处理」,
// 不包含局域网自动发现(UDP 7359 属非目标,清单见 README.md「已知限制」)。

/// `normalizeServerURL` 的返回值。
///
/// 之所以不只返回 URL:局域网 http 回退需要知道 scheme 是不是
/// 本算法补的 —— 用户明确写了 `https://` 就不得降级(API_CONTRACT.md 1.3、1.4)。
struct NormalizedServerURL: Sendable, Equatable {
    /// 规范化后的站点根:无 `/emby` 后缀、无末尾斜杠、无 query/fragment/userinfo
    let url: URL
    /// 用户输入里**没有**写 scheme、由本算法补了 `https://`。
    /// 只有这种情况才允许 API_CONTRACT.md 1.4 的 http 回退。
    let schemeWasInferred: Bool
}

/// 服务器地址规范化错误(API_CONTRACT.md 1.3)。
enum ServerURLError: Error, Equatable {
    /// 字符串无法解析为 URL
    case malformed
    /// scheme 不是 http / https
    case unsupportedScheme
    /// 缺少主机名
    case missingHost
}

/// 用户输入的服务器地址规范化。
/// 算法步骤与必测用例见 API_CONTRACT.md 1.3(共 10 步,按序执行)。
func normalizeServerURL(_ input: String) throws -> NormalizedServerURL {
    // 1. 去除首尾空白
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // 2. 不含 `://` 时补 https://,并记下 scheme 是推断出来的
    let schemeWasInferred = !trimmed.contains("://")
    let candidate = schemeWasInferred ? "https://" + trimmed : trimmed

    // 3. URLComponents 解析
    guard var components = URLComponents(string: candidate) else {
        throw ServerURLError.malformed
    }

    // 4. scheme 只允许 http / https(小写比较)
    guard let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        throw ServerURLError.unsupportedScheme
    }

    // 5. host 非 nil 且非空字符串
    // ⚠️ 实现陷阱(API_CONTRACT.md 1.3):`URLComponents(string: "https://")`
    //    的 host 是空字符串 "" 而不是 nil,`guard let host` 会放过它。
    guard let host = components.host, !host.isEmpty else {
        throw ServerURLError.missingHost
    }

    // 6. host 小写化
    components.host = host.lowercased()

    // 7. 端口等于 scheme 默认值(http=80, https=443)时置空
    switch (scheme, components.port) {
    case ("http", 80?), ("https", 443?):
        components.port = nil
    default:
        break
    }

    // 8. path 去掉末尾所有 "/"
    var path = components.path
    while path.hasSuffix("/") {
        path.removeLast()
    }

    // 9. path 以 /emby 结尾(大小写不敏感)时去掉该段
    if path.lowercased().hasSuffix("/emby") {
        path.removeLast("/emby".count)
    }
    components.path = path

    // 10. 丢弃 query 和 fragment
    components.query = nil
    components.fragment = nil

    // 11. 丢弃 userinfo(用户名/密码)。1.3 的十步没写这一条,但
    // CLAUDE.md「安全与隐私」明确「密码不做本地持久化」,
    // 若保留 `https://user:pass@host` 会把密码写进 UserDefaults,故剥除。
    components.user = nil
    components.password = nil

    guard let url = components.url else {
        throw ServerURLError.malformed
    }
    return NormalizedServerURL(url: url, schemeWasInferred: schemeWasInferred)
}

/// 判定 host 是否为 localhost / `.local` / 私有网段 / IPv6 本地地址。
/// 纯函数;判定表与必测用例见 API_CONTRACT.md 1.4。
/// 用途:scheme 回退**仅允许**对本地/私有地址把 https 降为 http。
func isLocalOrPrivateHost(_ host: String) -> Bool {
    let lowered = host.lowercased()

    // 主机名:localhost、*.local(大小写不敏感)
    if lowered == "localhost" || lowered.hasSuffix(".local") {
        return true
    }

    // IPv4:in_addr 在内存中即网络序,首字节就是第一段
    var v4 = in_addr()
    if lowered.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
        return withUnsafeBytes(of: v4) { bytes -> Bool in
            guard let b0 = bytes.first, let b1 = bytes.dropFirst().first else {
                return false
            }
            switch (b0, b1) {
            case (127, _), (10, _):          // 127.0.0.0/8、10.0.0.0/8
                return true
            case (172, 16...31):             // 172.16.0.0/12
                return true
            case (192, 168):                 // 192.168.0.0/16
                return true
            case (169, 254):                 // 169.254.0.0/16
                return true
            default:
                return false
            }
        }
    }

    // IPv6:::1、fc00::/7(唯一本地)、fe80::/10(链路本地)
    var v6 = in6_addr()
    if lowered.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
        return withUnsafeBytes(of: v6) { bytes -> Bool in
            let b = [UInt8](bytes)
            guard b.count == 16 else { return false }
            if b == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] {
                return true                              // ::1
            }
            if b[0] & 0xfe == 0xfc { return true }        // fc00::/7(fc/fd)
            if b[0] == 0xfe && b[1] & 0xc0 == 0x80 {     // fe80::/10
                return true
            }
            return false
        }
    }

    return false
}
