import Foundation

/// 分享链接的解析结果。转存前要先把搜索结果里那串 URL 拆成「哪个网盘 + 分享码 + 提取码」。
///
/// 为什么要拆:同一个链接可能是百度、夸克、115,三家的转存接口完全不同;
/// 而搜索结果里的链接形态五花八门(带 `?pwd=`、带 `#` 提取码、带中文说明、带多余空格)。
/// 这一步只做**确定性**解析,认不出来就返回 nil,⛔ 不猜网盘类型。
enum PanShareLink: Sendable, Equatable, Hashable {
    /// 百度:`https://pan.baidu.com/s/1xxxx?pwd=abcd`
    case baidu(shortURL: String, password: String?)
    /// 115:`https://115.com/s/swxxxx?password=abcd`
    case pan115(shareCode: String, receiveCode: String)
    /// 夸克 / UC:`https://pan.quark.cn/s/xxxx`
    ///
    /// ⚠️ 夸克本项目只有 TV 端只读接口(`docs/QUARK_API.md` §9),**没有转存能力**,
    /// 所以这一档只用于「识别出来并如实告诉用户转存不了」,⛔ 不要拿它去调接口。
    case quark(shareURL: String)
    case uc(shareURL: String)
    /// 其它网盘的分享地址:认得出是分享,但本版本不支持转存
    case other(cloudType: PanCloudType, shareURL: String)

    /// 与搜索结果里那条链接对得上
    var cloudType: PanCloudType {
        switch self {
        case .baidu: return .baidu
        case .pan115: return .pan115
        case .quark: return .quark
        case .uc: return .uc
        case .other(let type, _): return type
        }
    }

    /// 本版本能不能真的转存(115 与百度)
    var isTransferable: Bool {
        switch self {
        case .baidu, .pan115: return true
        case .quark, .uc, .other: return false
        }
    }

    /// 转存不了时的说明。⛔ 不说「暂不支持」了事,要说清是哪一家的什么限制。
    var unsupportedReason: String? {
        switch self {
        case .baidu, .pan115: return nil
        case .quark:
            return "夸克网盘目前只接了 TV 端的只读接口(不能建目录 / 不能转存),要保存请到夸克 App 里手动转存。"
        case .uc:
            return "UC 网盘还没有接来源,不能转存。"
        case .other(let type, _):
            return "\(type.displayName)还没有接来源,不能转存。"
        }
    }

    // MARK: - 解析

    /// 从一条资源链接里解析分享。`rawURL` 允许带前后说明文字(搜索源经常把标题和链接混在一行)。
    ///
    /// 只认**确定的域名**:`pan.baidu.com` / `115.com` / `115cdn.com` / `pan.quark.cn` / `drive.uc.cn`。
    /// 其余一律 `.other`,⛔ 不靠猜。
    static func parse(_ rawURL: String) -> PanShareLink? {
        guard let url = extractURL(from: rawURL), let host = url.host()?.lowercased() else {
            return nil
        }
        let path = url.path()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let value = query.first(where: { $0.name.lowercased() == name })?.value,
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        // `#abcd` 形态的提取码:百度老式链接会把码放在 fragment 里
        let fragment = url.fragment().flatMap { $0.isEmpty ? nil : $0 }

        if host == "pan.baidu.com" || host.hasSuffix(".pan.baidu.com") {
            // `/s/1xxxx` 是短链;`/share/init?surl=xxxx` 是另一种写法,转存接口要的是 22 位短码
            if let short = shortCode(fromBaiduPath: path) {
                return .baidu(
                    shortURL: short,
                    password: queryValue(["pwd", "password"]) ?? fragment)
            }
            if let surl = queryValue(["surl"]) {
                return .baidu(
                    shortURL: surl,
                    password: queryValue(["pwd", "password"]) ?? fragment)
            }
            return .other(cloudType: .baidu, shareURL: url.absoluteString)
        }

        if host == "115.com" || host.hasSuffix(".115.com") || host.hasSuffix("115cdn.com") {
            // `https://115.com/s/swxxxx?password=abcd`;也有 `https://115cdn.com/s/swxxxx`
            let components = path.split(separator: "/").map(String.init)
            if let index = components.firstIndex(of: "s"), components.count > index + 1 {
                return .pan115(
                    shareCode: components[index + 1],
                    receiveCode: queryValue(["password", "pwd"]) ?? "")
            }
            return .other(cloudType: .pan115, shareURL: url.absoluteString)
        }

        if host == "pan.quark.cn" || host.hasSuffix(".quark.cn") {
            return .quark(shareURL: url.absoluteString)
        }

        if host == "drive.uc.cn" || host.hasSuffix(".uc.cn") {
            return .uc(shareURL: url.absoluteString)
        }

        return .other(cloudType: PanCloudType.detect(fromHost: host), shareURL: url.absoluteString)
    }

    /// 百度短码:`/s/1AbCdEf` → `1AbCdEf`。
    ///
    /// ⚠️ 百度的 `short_url` 参数要的是**不带 `/s/` 的 22 位串**(`pan.baidu.com/union/doc` 的
    /// 「分享文件转存」:22 位分享短链,不包含完整链接前缀)。
    private static func shortCode(fromBaiduPath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(of: "s"), components.count > index + 1 else {
            return nil
        }
        let code = components[index + 1]
        return code.isEmpty ? nil : code
    }

    /// 从一段可能带说明文字的内容里抠出第一个 URL。
    private static func extractURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host() != nil { return url }
        // 搜索源常写成「标题 https://… 提取码:abcd」
        guard let range = trimmed.range(
            of: #"https?://[^\s<>"'）)，。；]+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(trimmed[range]))
    }
}

extension PanCloudType {
    /// 按域名判网盘类型(链接归一化与「本机有没有可接的来源」都用它)。
    static func detect(fromHost host: String) -> PanCloudType {
        let host = host.lowercased()
        if host.contains("baidu") { return .baidu }
        if host.contains("quark") { return .quark }
        if host.contains("115") { return .pan115 }
        if host.contains("aliyun") || host.contains("alipan") { return .aliyun }
        if host.contains("uc.cn") { return .uc }
        if host.contains("189.cn") || host.contains("tianyi") { return .tianyi }
        if host.contains("139.com") || host.contains("caiyun") { return .mobile }
        if host.contains("123pan") || host.contains("123684") { return .`123` }
        if host.contains("xunlei") { return .xunlei }
        if host.contains("pikpak") { return .pikpak }
        if host.contains("guangya") { return .guangya }
        if host.contains("magnet") { return .magnet }
        return .unknown
    }
}
