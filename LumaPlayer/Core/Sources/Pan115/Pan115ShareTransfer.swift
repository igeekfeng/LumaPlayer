import Foundation

/// 115 分享的读取与转存。
///
/// 端点与字段名逐字取自 `p115client` 的 `share_snap` / `share_receive`
/// (`webapi.115.com/share/snap`、`/share/receive`),见 `docs/PAN115_API.md` §10。
///
/// ⚠️ 这一层不碰登录态、不建目录、不猜路径:调用方给「分享码 + 提取码 + 自己的目标 cid」,
/// 它只负责「列出分享内容」和「把选中的 file_id 收进来」。
extension Pan115APIClient {

    /// 列分享里的一个目录。`cid` 传 `"0"` 是分享根目录。
    ///
    /// ⚠️ 115 的 `share/snap` 有 IP 级频控(文档原话:不登录也能看,但过于频繁会封 IP 一段时间),
    /// 所以这里走全 App 共用的限速器,且**只取一页** —— 转存只需要最外层那几个条目。
    func shareSnap(
        shareCode: String,
        receiveCode: String,
        cid: String,
        credential: Pan115Credential,
        limit: Int = Pan115SharePolicy.snapPageSize,
        offset: Int = 0
    ) async throws -> Pan115ShareSnapshot {
        let endpoint = Pan115Endpoint.shareSnap(
            shareCode: shareCode, receiveCode: receiveCode, cid: cid, limit: limit, offset: offset)
        let data = try await send(endpoint, credential: credential).data
        let response: Pan115ShareSnapResponse = try decode(data, endpoint: endpoint)
        return response.snapshot
    }

    /// 转存。返回 115 那边的结果(成功时通常只有 `state: true`)。
    ///
    /// ⛔ 不重试:转存是写操作,重发可能重复落盘,还会多烧一次风控面。
    func shareReceive(
        shareCode: String,
        receiveCode: String,
        fileIDs: [String],
        toCID cid: String,
        credential: Pan115Credential
    ) async throws {
        guard !fileIDs.isEmpty else { throw Pan115Error.invalidRequest("没有选中要转存的文件") }
        let endpoint = Pan115Endpoint.shareReceive(
            shareCode: shareCode, receiveCode: receiveCode, fileIDs: fileIDs, cid: cid)
        _ = try await send(endpoint, credential: credential).data
    }
}

/// 115 转存的请求纪律(与 `Pan115Policy` 分开:那些是读盘纪律,这些是分享纪律)。
enum Pan115SharePolicy {
    /// `share/snap` 一页取多少。转存只需要最外层条目,取 32 与 `p115client` 的默认一致。
    static let snapPageSize = 32
    /// 转存接口在 UI 上的最短间隔提示(秒)。真正的频控由 `Pan115RateLimiter` 兜。
    static let minimumTransferInterval: TimeInterval = 1.5
}

/// `share/snap` 的一页。
struct Pan115ShareSnapshot: Sendable, Equatable {
    let entries: [Pan115ShareEntry]
    let totalCount: Int?
    /// 分享本身的状态(`state` 为 true 且没有错误码即视为可用)
    let isAvailable: Bool
}

/// 分享里的一个条目。
///
/// ⚠️ 字段名与 115 网盘自己的 `files` 接口**不一样**:分享侧用 `fid`(不是 `fid`/`cid` 混用),
/// 且 `file_id` 是转存时唯一被 `/share/receive` 认的标识。
struct Pan115ShareEntry: Sendable, Equatable {
    /// 转存时要传的 id
    let fileID: String
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64?
    /// 修改时间(unix 秒)
    let updatedAt: Int?

    /// 展示用的「是文件还是目录」标记,⛔ 不猜类型
    var kindDescription: String { isDirectory ? "文件夹" : "文件" }
}

// MARK: - 线格式

struct Pan115ShareSnapResponse: Decodable, Sendable {
    let state: Bool?
    let code: Int?
    let message: String?
    let data: Data?

    struct Data: Decodable, Sendable {
        let count: Int?
        let list: [Entry]?
    }

    struct Entry: Decodable, Sendable {
        let fid: String?
        let cid: String?
        let n: String?
        let s: Int64?
        let t: Int?
        /// `1` = 目录
        let isDir: Int?

        enum CodingKeys: String, CodingKey {
            case fid, cid, n, s, t
            case isDir = "is_dir"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fid = Self.string(container, .fid)
            cid = Self.string(container, .cid)
            n = Self.string(container, .n)
            s = Self.int64(container, .s)
            t = Self.int(container, .t)
            isDir = Self.int(container, .isDir)
        }

        /// 115 的 id 有时是数字、有时是字符串(老接口的数字 id 超过 Int32,`JSONDecoder` 解 Int 会溢出)。
        /// ⛔ 统一按字符串解,不在这里丢条目。
        private static func string(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) { return String(value) }
            return nil
        }

        private static func int(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value)
            }
            return nil
        }

        private static func int64(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) -> Int64? {
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int64(value)
            }
            return nil
        }
    }

    var snapshot: Pan115ShareSnapshot {
        let entries = (data?.list ?? []).compactMap { entry -> Pan115ShareEntry? in
            // 目录用 cid,文件用 fid;转存时 `/share/receive` 要的是这两者里的那一个
            let id = entry.fid ?? entry.cid
            guard let id, !id.isEmpty else { return nil }
            return Pan115ShareEntry(
                fileID: id,
                name: entry.n ?? "未命名",
                isDirectory: entry.isDir == 1,
                sizeBytes: entry.s,
                updatedAt: entry.t)
        }
        return Pan115ShareSnapshot(
            entries: entries,
            totalCount: data?.count,
            // `state` 缺省时按可用处理:老实例可能不回这个字段,没有错误码就当成功
            isAvailable: state != false)
    }
}
