import Darwin
import Foundation

// 手动添加服务器时的地址规范化 + 本地地址判定,纯函数、零网络(API_CONTRACT.md 1.3)。
// 不含局域网自动发现(UDP 7359 属非目标)。

struct NormalizedServerURL: Sendable, Equatable {
    /// 站点根:无 `/emby` 后缀、无末尾斜杠、无 query/fragment/userinfo
    let url: URL
    /// 用户没写 scheme、由本算法补了 `https://`。只有这种情况才允许 http 回退(API_CONTRACT.md 1.4)
    let schemeWasInferred: Bool
}

enum ServerURLError: Error, Equatable {
    case malformed
    /// 不是 http / https
    case unsupportedScheme
    case missingHost
}

/// 步骤与必测用例见 API_CONTRACT.md 1.3,按序执行。
func normalizeServerURL(_ input: String) throws -> NormalizedServerURL {
    // 1. 去除首尾空白
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // 2. 不含 `://` 时补 https://
    let schemeWasInferred = !trimmed.contains("://")
    let candidate = schemeWasInferred ? "https://" + trimmed : trimmed

    // 3. 解析
    guard var components = URLComponents(string: candidate) else {
        throw ServerURLError.malformed
    }

    // 4. scheme 只允许 http / https
    guard let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        throw ServerURLError.unsupportedScheme
    }

    // 5. ⚠️ `URLComponents(string: "https://")` 的 host 是 "" 而不是 nil
    guard let host = components.host, !host.isEmpty else {
        throw ServerURLError.missingHost
    }

    // 6. host 小写化
    components.host = host.lowercased()

    // 7. 默认端口置空
    switch (scheme, components.port) {
    case ("http", 80?), ("https", 443?):
        components.port = nil
    default:
        break
    }

    // 8. 去末尾 "/"
    var path = components.path
    while path.hasSuffix("/") {
        path.removeLast()
    }

    // 9. 去掉末尾 /emby(大小写不敏感)
    if path.lowercased().hasSuffix("/emby") {
        path.removeLast("/emby".count)
    }
    components.path = path

    // 10. 丢弃 query 和 fragment
    components.query = nil
    components.fragment = nil

    // 11.(1.3 之外)丢弃 userinfo:否则 `https://user:pass@host` 会把密码写进 UserDefaults
    components.user = nil
    components.password = nil

    guard let url = components.url else {
        throw ServerURLError.malformed
    }
    return NormalizedServerURL(url: url, schemeWasInferred: schemeWasInferred)
}

/// localhost / `.local` / 私有网段 / IPv6 本地地址。判定表见 API_CONTRACT.md 1.4。
/// http 回退**仅允许**对这些地址。
func isLocalOrPrivateHost(_ host: String) -> Bool {
    let lowered = host.lowercased()

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
