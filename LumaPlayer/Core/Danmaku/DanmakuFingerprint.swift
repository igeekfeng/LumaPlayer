import CryptoKit
import Foundation

/// 弹弹play `/match` 的 `fileHash`:文件前 16 MiB 的 MD5(32 位小写 hex,`docs/DANDANPLAY_API.md` §2),
/// 「同一份文件」的唯一硬证据;不算只能靠文件名模糊匹配(Emby 只有合成名,Q45)。
///
/// 网络这一路只用于 Emby 直连流(这 16 MiB 正是播放器接下来要读的字节);⛔ 百度网盘不算(额外耗网盘流量)。
/// - 只在 `DirectStream` 且 `Size` 已知时试:转码流的字节不是源文件;
/// - `Range: bytes=0-16777215`,严格校验 `Content-Range`;服务端忽略 Range 回 200 时只在整文件 ≤ 16 MiB 才接受,
///   ⛔ 绝不为算指纹把整部片下下来;
/// - 任何一步不满足返回 nil(退回文件名匹配),⛔ 不抛错打断播放。
///
/// 与 `PlaybackFailureProbe`(诊断路径、失败时触发)纪律一致但用途不同,刻意分开。
enum DanmakuFingerprint {

    /// 只取前 16 MiB(不是前后各 16 MiB)。
    static let byteCount = 16 * 1024 * 1024

    /// - Parameters:
    ///   - headers:与播放请求完全一致的认证头
    ///   - expectedFileSize:`MediaSource.Size`;nil = 未知
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
            // 拿不到就走文件名匹配,⛔ 不挡播放
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard let accepted = acceptedByteCount(http: http, received: data.count, expectedFileSize: expectedFileSize)
        else { return nil }
        guard data.count == accepted else { return nil }
        return MD5.hash(data)
    }

    /// 本机文件(本地文件夹来源):读前 16 MiB,不足就是整个文件。不花流量,总是值得算
    /// (仍受设置开关管,见 `PlayerViewModel.mediaFingerprint`)。读不出返回 nil。
    static func md5(ofFileAt url: URL) async -> String? {
        guard url.isFileURL else { return nil }
        // 阻塞 IO,别占主线程
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: byteCount), !data.isEmpty else { return nil }
            return MD5.hash(data)
        }
        return await task.value
    }

    /// 返回应该收到的字节数;不接受返回 nil。抽出来便于离线测试每条拒绝分支。
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
            // 总长与已知大小不一致说明是别的文件 / 版本
            if let expectedFileSize, expectedFileSize != total { return nil }
            let expectedEnd = min(Int64(byteCount), total) - 1
            guard range.end == expectedEnd else { return nil }
            return Int(range.end - range.start + 1)
        case 200:
            // 服务端忽略了 Range:只有整文件 ≤ 16 MiB 才安全
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

    /// 只用于弹弹play 协议,不是安全用途。
    enum MD5 {
        static func hash(_ data: Data) -> String {
            Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
