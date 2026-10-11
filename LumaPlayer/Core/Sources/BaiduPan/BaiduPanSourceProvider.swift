import Foundation

/// 百度网盘来源的内容能力(列库 / 列条目)。
///
/// ## 它把「一次目录读取」的全部步骤收在一处
///
/// 列目录 → 合成条目 → **批量**换封面地址。上层(浏览页)只管拿 `[SourceItem]`,
/// ⛔ 不必知道封面为什么要另外发一次请求。
///
/// ⛔ 播放不走它 —— 那条走 `BaiduPanSessionPreparer`(生命周期与浏览不同)。
actor BaiduPanSourceProvider: SourceProvider {

    /// 封面取到多宽。
    ///
    /// ⚠️ 百度 `dlink` 给的是**原图**,没有服务端缩放参数,所以这个值只用于
    /// **缓存 key 分段**(与 `ImageSpec.maxWidth` 的口径一致)——
    /// 它不影响取到的字节数,只是让不同尺寸的卡片各占一格缓存。
    static let coverMaxWidth = 400

    nonisolated let sourceID: UUID
    private let connection: BaiduPanConnection
    /// 应用目录名(空状态提示要用)
    private let folderName: String

    init(connection: BaiduPanConnection, sourceID: UUID, folderName: String) {
        self.connection = connection
        self.sourceID = sourceID
        self.folderName = folderName
    }

    // MARK: - SourceProvider

    /// 百度来源只有一个「库」入口:进入时的起点(片库根,没设就是应用目录)。
    func libraries() async throws -> [SourceLibrary] {
        let root = try await connection.applicationDirectory()
        let start = try await connection.libraryRoot() ?? root
        return [
            SourceLibrary(
                ref: SourceLibraryRef(sourceID: sourceID, libraryID: start),
                title: folderName.isEmpty ? "百度网盘" : folderName,
                kind: .folder
            )
        ]
    }

    func items(in library: SourceLibraryRef) async throws -> [SourceItem] {
        try await content(directory: library.libraryID).items
    }

    /// 一次目录读取的**完整结果**。
    ///
    /// 为什么把原始文件一起交回去:合成后的 `SourceItem` 只保留展示所需字段,
    /// 而播放与「进目录」要的 `path` / 真实文件名不在里面。
    /// ⛔ 让调用方**再列一次目录**去拿它们是不可接受的 ——
    /// 未审核应用配额 10 次/小时(`docs/BAIDU_PAN_API.md`)。
    struct DirectoryContent: Sendable {
        let items: [SourceItem]
        /// `fs_id` → 原始文件
        let filesByID: [UInt64: BaiduPanFile]
    }

    /// 列一个目录 → 合成条目 → **批量**换封面地址(全程只发两次请求:
    /// 一次 `list`、一次 `filemetas`)。
    func content(directory: String) async throws -> DirectoryContent {
        let files = try await connection.files(inDirectory: directory)
        let synthesized = BaiduPanMetadataSynthesizer.synthesize(
            files: files, sourceID: sourceID)

        // 封面:收集所有配到的图片 `fs_id`,**一次批量**换地址 ——
        // 逐个取会烧光配额,见 `coverURLs`。
        let coverIDs = Set(synthesized.compactMap { $0.cover?.fsID })
        let coverURLs = await connection.coverURLs(for: Array(coverIDs))

        let items = synthesized.map { entry in
            guard let cover = entry.cover, let url = coverURLs[cover.fsID] else {
                // 没配到图 / 换了地址也拿不到 → 保持 nil,UI 降级成图标卡
                return entry.item
            }
            return entry.item.withPoster(
                .remote(
                    ownerID: sourceID,
                    url: url,
                    // ⚠️ UA 必须与 `dlink` 的 sign 绑定的一致:不给会撞 `31326` 防盗链
                    // (`docs/BAIDU_PAN_API.md` §1)。⛔ 不能换成别的 UA。
                    headers: ["User-Agent": BaiduPanUserAgent.download],
                    cacheKey: ImageDescriptor.baiduCoverKey(
                        sourceID: sourceID,
                        fsID: cover.fsID,
                        // 封面文件的 `server_mtime` 就是缓存 key 的版本段:
                        // 换了封面 → key 变 → 不会再端出旧图
                        modifiedAt: cover.modifiedAt,
                        maxWidth: Self.coverMaxWidth
                    )
                )
            )
        }
        return DirectoryContent(
            items: items,
            filesByID: Dictionary(uniqueKeysWithValues: files.map { ($0.fsID, $0) })
        )
    }
}
