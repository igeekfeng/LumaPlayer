import Foundation

/// 图片从哪来。
///
/// ⛔ `PosterImage` 只认这个,不再直接拼 Emby 端点 —— 否则百度来源的图取不到
/// (`docs/SOURCE_ABSTRACTION_PLAN.md` §4.5)。
///
/// ## `cacheKey` 必须与 `origin` 分开
///
/// 百度的 `dlink` 是**临时地址**(8 小时有效,见 `docs/BAIDU_PAN_API.md` §2.2)。
/// 若把它写进缓存 key,同一个文件过 8 小时就会被当成一张新图重新下载。
/// 所以 key 由调用方按「来源 + 内容 id + **内容版本**」给,`origin` 只负责
/// 「怎么取字节」。
struct ImageDescriptor: Sendable, Equatable, Hashable {

    enum Origin: Sendable, Equatable, Hashable {
        /// Emby 图片端点(要带 `X-Emby-Token`,`API_CONTRACT.md` 3.3)
        case emby(ImageSpec)
        /// 一个自带凭据的远端地址(百度 `dlink`)。
        /// ⛔ 不要为它套自定义 scheme / 资源加载器:它就是普通 https 地址。
        case remote(url: URL, headers: [String: String])
        /// 本地文件(预留:将来把 sidecar 图下到沙盒后走这条)
        case localFile(URL)
    }

    /// 这张图属于哪个来源。
    ///
    /// 用途:磁盘缓存按它分目录,删来源时按它整片清掉
    /// (`PosterDiskCache.purge(ownerID:)`)。
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

    /// 能不能进磁盘缓存。
    ///
    /// ⚠️ 沿用 `API_CONTRACT.md` 3.3 那条硬规则:**没有版本标识的图不进磁盘缓存**
    /// —— key 不含版本就可能把旧图当新图端出来。
    /// Emby 的版本标识是 `ImageSpec.tag`;百度那边由 `baiduCoverKey` 把
    /// 封面文件的修改时间编进 key,所以它自带版本。
    var isDiskCacheable: Bool {
        switch origin {
        case .emby(let spec): return spec.tag != nil
        case .remote, .localFile: return true
        }
    }

    /// 可持久化的封面快照。
    ///
    /// ## 为什么需要它
    ///
    /// 本地续播库(`WatchProgressStore`)要记住「这条续播卡片的封面长什么样」,
    /// 而 `ImageDescriptor` 本身不是 `Codable`(它带 `ImageSpec` 这类 Emby 模型)。
    /// 这里把**远端封面**要的东西单拎出来存:`ownerID`(磁盘缓存分区)+
    /// `cacheKey`(版本标识)+ 取字节用的地址与请求头。
    ///
    /// ## ⚠️ `url` 是**临时**地址
    ///
    /// 百度的 `dlink` 8 小时过期(`docs/BAIDU_PAN_API.md` §2.2)。所以这张快照
    /// 恢复出来的图**只在两种情况下出得来**:磁盘缓存还留着这张图(`cacheKey`
    /// 含封面文件的 `server_mtime`,内容变了 key 就变),或者地址还没过期。
    /// 都不满足时按 `PosterImage` 的既定处置降级成占位图 —— ⛔ 不假装有封面。
    /// 它落在 0600、不进备份的续播库文件里,与凭据文件同一敏感级。
    struct Snapshot: Codable, Sendable, Equatable {
        let ownerID: UUID
        let url: URL
        let headers: [String: String]
        let cacheKey: String
    }

    /// 这张图能不能折成快照。只有远端图可以 ——
    /// Emby 图要带服务端认证头、语义绑在 `ImageSpec` 上,不进本地续播库。
    var snapshot: Snapshot? {
        guard case .remote(let url, let headers) = origin else { return nil }
        return Snapshot(ownerID: ownerID, url: url, headers: headers, cacheKey: cacheKey)
    }

    /// 百度网盘里一张封面的缓存 key:来源 + `fs_id` + **文件修改时间**。
    ///
    /// ⚠️ 带 `modifiedAt`:它就是百度侧的「版本标识」。用户在网盘里换了封面图,
    /// `server_mtime` 会变 → key 变 → 拉到新图而不是端出旧缓存。
    /// ⛔ 不带时间戳的话,换了封面永远看不到新的 —— 与 `ImageSpec` 不缓存无 Tag
    /// 图片是同一个理由。
    static func baiduCoverKey(
        sourceID: UUID,
        fsID: UInt64,
        modifiedAt: Date?,
        maxWidth: Int
    ) -> String {
        let stamp = modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "nomtime"
        return "baidu|\(sourceID.uuidString)|\(fsID)|\(stamp)|cover|\(maxWidth)"
    }

    /// TMDB 一张海报的缓存 key:来源 + `poster_path` + 档位。
    ///
    /// ⚠️ `poster_path` **自带版本语义**:换了海报 TMDB 会换路径
    /// (`docs/TMDB_API.md` §4),所以它直接当版本段 —— 与 `baiduCoverKey`
    /// 拿 `server_mtime` 当版本段是同一个角色。
    /// ⛔ 不要拿 TMDB 条目 id 当版本:`id` 不变而海报会变,那样换了海报仍端旧图。
    ///
    /// ⚠️ 分集剧照(`episodes[].still_path`,§8)也走它:拼法与版本语义**完全一致**
    /// (`path` 是版本段),⛔ 不另立一个只有名字不同的 key。
    static func tmdbPosterKey(sourceID: UUID, posterPath: String, size: String) -> String {
        "tmdb|\(sourceID.uuidString)|\(posterPath)|\(size)"
    }
}

extension ImageDescriptor {
    /// 从持久化的快照恢复。
    ///
    /// ⚠️ 放在 extension 里而不是类型体内:类型体内定义任何 `init` 都会**抑制**
    /// 合成的逐成员构造器,而 `emby(_:)` / `remote(...)` / `localFile(...)`
    /// 三个工厂都靠那个构造器。
    init(snapshot: Snapshot) {
        self.init(
            ownerID: snapshot.ownerID,
            origin: .remote(url: snapshot.url, headers: snapshot.headers),
            cacheKey: snapshot.cacheKey
        )
    }
}
