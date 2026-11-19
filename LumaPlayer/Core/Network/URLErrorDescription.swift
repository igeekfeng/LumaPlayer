import Foundation

/// 传输层失败给用户看的一句话。
///
/// ⛔ 不把 `NSURLErrorDomain -1009:...` 这类机器码端到界面:用户看不懂,也提示不了该做什么
/// (PITFALLS.md Q31 的脱敏口径之外,这里还要求可读)。
enum URLErrorDescription {
    static func userText(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "本机没有网络连接"
        case .timedOut: return "请求超时"
        case .cannotFindHost, .dnsLookupFailed: return "域名解析失败"
        case .cannotConnectToHost, .networkConnectionLost: return "连接被断开"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS 握手失败"
        default: return "网络错误(\(error.code.rawValue))"
        }
    }
}
