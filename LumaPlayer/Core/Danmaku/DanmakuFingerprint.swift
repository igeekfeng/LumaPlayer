import CryptoKit
import Foundation

/// 弹弹play 匹配用的**媒体指纹**:文件前 16 MiB 的 MD5(32 位小写 hex)。
///
/// ## 为什么要算它
///
/// `/match` 的 `fileHash` 是「同一份文件」的唯一硬证据(`docs/DANDANPLAY_API.md` §2:
/// 官方描述就是「文件前 16MB 数据的 32 位 MD5」)。不算它,`/match` 只能拿文件名猜;
/// Emby 那一路连文件名都拿不到(只能合成 `剧名 S01E03`),命中率全押在模糊匹配上
/// (`KNOWN_ISSUES.md` Q45)。
///
/// ## 成本与边界
///
/// `DANMAKU.md` §6 原先的判断是「为匹配多拉 16 MB 不划算」。这条判断对**百度网盘**
/// 成立(要额外消耗网盘流量);对 **Emby 直连流**不成立 —— 播放器本来就要从头读这个文件,
/// 这 16 MiB 正是它接下来要读的字节,服务端与内核的 HTTP 缓存都可能已经有一份。
///
/// 因此本类型**只服务 Emby 直连流**,并且:
///
/// - 只在 `DirectStream` 且 `Size` 已知时才试 —— 转码流的前 16 MiB 是编码器输出,
///   与源文件不是同一份字节,算出来的 MD5 没有意义;
/// - 走 `Range: bytes=0-16777215`,并**严格校验 `Content-Range`**:只接受 206 且
///   `start == 0`、`end` 与总长自洽;服务端若忽略 Range 回 200,**只有**在整文件
///   ≤ 16 MiB 时才接受 —— ⛔ 绝不为算指纹把一部电影整段下载下来;
/// - 任何一步不满足就返回 nil(调用方退回文件名匹配),⛔ 不抛错打断播放。
///
/// ## 为什么单独一个类型
///
/// `PlaybackFailureProbe` 已经在做同一件事(播放失败后补一次 `Range` 探测),但那是
/// **诊断**路径、按失败触发;这里要的是**匹配**路径、按起播触发。两者的纪律
/// (不跟随跨 host 跳转、只探一次)一致,但触发条件与用途不同,合在一起会让
/// 两边的注释互相污染。
enum DanmakuFingerprint {

    /// 官方固定取前 16 MiB(不是前后各 16 MiB)。
    static let byteCount = 16 * 1024 * 1024

    /// 计算指纹。拿不到 / 不满足条件都返回 nil。
    ///
    /// - Parameters:
    ///   - url:直连流地址(`PlaybackPlan.directStream` 的 URL)
    ///   - headers:播放用的认证头(与播放请求完全一致)
    ///   - expectedFileSize:`MediaSource.Size`;nil = 未知,此时只接受带总长的 `Content-Range`
    ///   - session:可注入(测试用 mock 协议)
    static func md5(
        of url: URL,
        headers: [String: String],
        expectedFileSize: Int64?,
        session: URLSession
    ) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-\(byteCount - 1)", forHTTPHeaderField: "Range")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(ClientUserAgent.value, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 指纹是**锦上添花**:拿不到就走文件名匹配,⛔ 不让它挡住播放。
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard let accepted = acceptedByteCount(http: http, received: data.count, expectedFileSize: expectedFileSize)
        else { return nil }
        guard data.count == accepted else { return nil }
        return MD5.hash(data)
    }

    /// 校验响应是否可以拿来算指纹,返回**应该收到的字节数**;不接受返回 nil。
    ///
    /// 单独抽出来是为了能离线覆盖每条拒绝分支(真实服务器上没法构造)。
    static func acceptedByteCount(
        http: HTTPURLResponse, received: Int, expectedFileSize: Int64?
    ) -> Int? {
        switch http.statusCode {
        case 206:
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = ContentRange(header), range.start == 0
            else { return nil }
            guard let total = range.total else {
                // 没有总长时只能要求「正好是前 16 MiB」
                return range.end == Int64(byteCount - 1) ? byteCount : nil
            }
            // 有总长:必须与已知的文件大小一致(不一致说明服务端给的是别的文件 / 别的版本)
            if let expectedFileSize, expectedFileSize != total { return nil }
            let expectedEnd = min(Int64(byteCount), total) - 1
            guard range.end == expectedEnd else { return nil }
            return Int(range.end - range.start + 1)
        case 200:
            // 服务端忽略了 Range:只有整文件 ≤ 16 MiB 时才安全(否则会把整部片下下来)
            guard let expectedFileSize, expectedFileSize > 0, expectedFileSize <= Int64(byteCount)
            else { return nil }
            guard received == Int(expectedFileSize) else { return nil }
            return Int(expectedFileSize)
        default:
            return nil
        }
    }

    /// `Content-Range: bytes 0-16777215/123456789`
    struct ContentRange: Equatable {
        let start: Int64
        let end: Int64
        /// `/` 后面是 `*` 时为 nil
        let total: Int64?

        init?(_ value: String) {
            let fields = value.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
            let parts = fields[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let bounds = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard bounds.count == 2,
                  let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start >= 0, end >= start, end < Int64.max
            else { return nil }
            if parts[1] == "*" {
                total = nil
            } else {
                guard let parsed = Int64(parts[1]), parsed > 0, end < parsed else { return nil }
                total = parsed
            }
            self.start = start
            self.end = end
        }
    }

    /// MD5(只用于弹弹play 协议,不是安全用途)。
    enum MD5 {
        static func hash(_ data: Data) -> String {
            Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
