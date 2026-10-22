import Foundation

/// 图片从哪来。`PosterImage` 只认这个,⛔ 不直接拼 Emby 端点。
///
/// `cacheKey` 与 `origin` 分开:百度 `dlink` 8 小时过期(`docs/BAIDU_PAN_API.md` §2.2),
/// 进了 key 就会被当成新图重下。key 由调用方按「来源 + 内容 id + 内容版本」给,`origin` 只管怎么取字节。
struct ImageDescriptor: Sendable, Equatable, Hashable {

    enum Origin: Sendable, Equatable, Hashable {
        /// Emby 图片端点(要带 `X-Emby-Token`,`API_CONTRACT.md` 3.3)
        case emby(ImageSpec)
        /// 自带凭据的普通 https 地址(百度 `dlink`)
        case remote(url: URL, headers: [String: String])
        /// 本地文件夹来源里的封面图;读之前要先打开该来源的访问权(`LocalFolderAccess`)
        case localFile(URL)
    }

    /// 所属来源。磁盘缓存按它分目录,删来源时整片清掉(`PosterDiskCache.purge(ownerID:)`)
    let ownerID: UUID
    let origin: Origin
    /// 稳定的缓存 key。⛔ 不得含会过期的临时地址,但**必须含内容版本**。
    let cacheKey: String

    static func emby(_ spec: ImageSpec) -> ImageDescriptor {
        ImageDescriptor(ownerID: spec.serverID, origin: .emby(spec), cacheKey: spec.cacheKey)
    }

    static func remote(
        ownerID: UUID,
        url: URL,
        headers: [String: String],
        cacheKey: String
    ) -> ImageDescriptor {
        ImageDescriptor(
            ownerID: ownerID,
            origin: .remote(url: url, headers: headers),
            cacheKey: cacheKey
        )
    }

    static func localFile(ownerID: UUID, url: URL, cacheKey: String) -> ImageDescriptor {
        ImageDescriptor(ownerID: ownerID, origin: .localFile(url), cacheKey: cacheKey)
    }

    /// 没有版本标识的图不进磁盘缓存(`API_CONTRACT.md` 3.3)。Emby 看 `ImageSpec.tag`;
    /// 其余来源的 key 已含修改时间 / 路径版本。
    var isDiskCacheable: Bool {
        switch origin {
        case .emby(let spec): return spec.tag != nil
        case .remote, .localFile: return true
        }
    }

    /// 本地续播库(`WatchProgressStore`)里存的封面(`ImageDescriptor` 本身不是 `Codable`)。
    ///
    /// `url` 可能已过期(`dlink`)或失效(本机路径挪了):只能靠磁盘缓存兜,兜不住就降级成占位图。
    /// 含请求头,所在文件与凭据文件同一敏感级(0600、不进备份)。
    struct Snapshot: Codable, Sendable, Equatable {
        let ownerID: UUID
        let url: URL
        let headers: [String: String]
        let cacheKey: String
    }

    /// Emby 图要带服务端认证头,不进本地续播库,返回 nil。
    var snapshot: Snapshot? {
        switch origin {
        case .remote(let url, let headers):
            return Snapshot(ownerID: ownerID, url: url, headers: headers, cacheKey: cacheKey)
        case .localFile(let url):
            return Snapshot(ownerID: ownerID, url: url, headers: [:], cacheKey: cacheKey)
        case .emby:
            return nil
        }
    }

    /// 地址会过期(百度 `dlink`),⛔ 不能进跨天的缓存(如 `BaiduPanScrapeCache`)。
    /// 按 `cacheKey` 命名空间前缀判断,与下面的 `…Key(…)` 工厂对应。
    var hasExpiringURL: Bool { cacheKey.hasPrefix("baidu|") }

    /// 来源 + `fs_id` + 修改时间。修改时间就是版本:换了封面 key 就变。
    static func baiduCoverKey(
        sourceID: UUID,
        fsID: UInt64,
        modifiedAt: Date?,
        maxWidth: Int
    ) -> String {
        let stamp = modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "nomtime"
        return "baidu|\(sourceID.uuidString)|\(fsID)|\(stamp)|cover|\(maxWidth)"
    }

    /// 来源 + `poster_path` + 档位。换海报 TMDB 会换路径(`docs/TMDB_API.md` §4),路径就是版本;
    /// ⛔ 不用条目 id(id 不变海报会变)。分集剧照 `still_path` 也用它。
    static func tmdbPosterKey(sourceID: UUID, posterPath: String, size: String) -> String {
        "tmdb|\(sourceID.uuidString)|\(posterPath)|\(size)"
    }

    /// 同 `baiduCoverKey`;命名空间单独用 `local|`,因为本机路径不过期(见 `hasExpiringURL`)。
    static func localCoverKey(
        sourceID: UUID,
        fileID: UInt64,
        modifiedAt: Date?,
        maxWidth: Int
    ) -> String {
        let stamp = modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "nomtime"
        return "local|\(sourceID.uuidString)|\(fileID)|\(stamp)|cover|\(maxWidth)"
    }
}

extension ImageDescriptor {
    /// 放在 extension 里,以保留合成的逐成员构造器(上面三个工厂要用)。
    /// 快照不记图的种类,`file://` 即本机文件。
    init(snapshot: Snapshot) {
        self.init(
            ownerID: snapshot.ownerID,
            origin: snapshot.url.isFileURL
                ? .localFile(snapshot.url)
                : .remote(url: snapshot.url, headers: snapshot.headers),
            cacheKey: snapshot.cacheKey
        )
    }
}
