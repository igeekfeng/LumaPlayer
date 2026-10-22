import Foundation

/// 百度网盘源的连接(actor):授权状态机 + 自动刷新 + 内容读取。
///
/// ## 与 `ServerConnection` 的对应关系
///
/// 形状照 `ServerConnection`(actor、token 不共享),但语义完全不同:
/// - **只有一份**:一个 App 对应开放平台上一个应用,一个用户授权一次
///   (不像 Emby 那样按服务器分);
/// - **token 在查询串上**,不在请求头;
/// - **没有播放上报**(`docs/BAIDU_PAN_API.md` 没有这类端点),
///   所以这个 actor 里唯一的写接口就是 `deleteFile(at:)`(§2.4)。
///
/// ## ★ `refresh_token` 单飞(`docs/BAIDU_PAN_API.md` §6 的三条坑)
///
/// 这是本类型最要紧的一件事:
///
/// 1. `refresh_token` **只能用一次**,刷新后旧的立刻失效 → 必须把响应里新的落盘;
/// 2. 刷新请求**失败会导致旧 `refresh_token` 失效** → 失败=重新授权,
///    ⛔ **不得**用旧的 refresh_token 循环重试(那只会反复作废);
/// 3. 同一应用**第二次申请 token 会让第一次的失效** → 只保留一份。
///
/// 所以刷新走 `refreshTask` 单飞:进行中时并发调用方 await 同一个 Task,
/// 任意时刻最多一条刷新请求在飞。
actor BaiduPanConnection {

    private let credentials: CredentialStore
    private let client: BaiduPanAPIClient
    /// 进行中的刷新。见类型注释的「单飞」。
    private var refreshTask: Task<BaiduPanTokenBundle, any Error>?
    /// 最近一次拿到的账号信息(不落盘:它只是个展示用的快照,随时会变,
    /// 存起来反而要处理「什么时候该失效」)。
    private var cachedAccount: BaiduPanAccount?

    init(credentials: CredentialStore, client: BaiduPanAPIClient = BaiduPanAPIClient()) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: - 配置与授权状态

    /// 现在该显示哪一屏。会**读凭据文件**但**不发网络请求** ——
    /// 「token 还有效吗」由第一次真正的请求来回答(与 Emby 同一条:
    /// 不静默重登,也不拿探活请求当登录)。
    ///
    /// ⚠️ 配置不全时返回 `.unconfigured` 而不是抛错:那是**一屏**
    /// (要去开放平台建应用),不是一个错误。
    func authorization() async throws -> BaiduPanAuthorization {
        guard let configuration = try? await appConfiguration() else {
            return .unconfigured
        }
        guard try await credentials.baiduPanToken() != nil else {
            return .needsAuthorization(folderName: configuration.folderName)
        }
        return .authorized(account: cachedAccount)
    }

    /// 应用配置(AppKey / SecretKey / 应用目录名)。
    /// 缺任何一项都抛具体原因 —— UI 直接拿去显示,不用自己拼文案。
    func appConfiguration() async throws -> CredentialStore.BaiduPanAppConfiguration {
        guard let configuration = try await credentials.baiduPanAppConfiguration() else {
            throw BaiduPanError.appCredentialsMissing
        }
        guard !configuration.appKey.isEmpty, !configuration.secretKey.isEmpty else {
            throw BaiduPanError.appCredentialsMissing
        }
        guard !normalizedFolderName(configuration.folderName).isEmpty else {
            throw BaiduPanError.configuration(
                "还没填「应用目录名」:第三方应用只能访问 /apps/{应用目录名} 下的文件。")
        }
        return configuration
    }

    /// - Returns: 已有的片库根是否已失效(换了 AppKey / SecretKey 或应用目录名)。
    ///   调用方据此清掉各来源的片库根 —— 它们都指向旧的应用目录。
    ///   ⚠️ 这里不自己清:片库根按**来源**存,这个 actor 不知道有哪些来源。
    @discardableResult
    func saveConfiguration(appKey: String, secretKey: String, folderName: String) async throws -> Bool {
        let previous = try? await credentials.baiduPanAppConfiguration()
        let next = CredentialStore.BaiduPanAppConfiguration(
            appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            folderName: normalizedFolderName(folderName)
        )
        try await credentials.saveBaiduPanAppConfiguration(next)

        // 只改了「应用目录名」不必重新扫码:token 是那对密钥签发的,
        // 与目录名无关。⛔ 无条件删 token 会让人为了改个笔误再扫一次码。
        guard previous?.appKey != next.appKey || previous?.secretKey != next.secretKey else {
            // 目录名换了 → 旧片库根必然落在新应用目录之外,全部失效
            return previous?.folderName != next.folderName
        }
        // 换了应用(AppKey / SecretKey 变了)就是换了一套授权,token 必须一起作废
        try await credentials.deleteBaiduPanToken()
        cachedAccount = nil
        return true
    }

    /// 第三方应用能访问的根目录:`/apps/{应用目录名}`(`docs/BAIDU_PAN_API.md` §3)。
    func applicationDirectory() async throws -> String {
        let configuration = try await appConfiguration()
        return "/apps/\(normalizedFolderName(configuration.folderName))"
    }

    // MARK: - 片库根

    /// 某个来源的片库根(**已校验**:落在应用目录之内)。nil = 没设,用应用目录。
    ///
    /// ⛔ 存下来的路径**每次读都要重新校验**:用户可能回头改了「应用目录名」
    /// (改完旧路径整个失效),也可能在网盘里把那个子目录删了。
    /// 校验不过就**静默当作没设** —— ⛔ 不报「配置损坏」:
    /// 比起让人卡在一页打不开的错误上,回到能用的起点更有用。
    func libraryRoot(for sourceID: UUID) async throws -> BaiduPanLibraryRoot? {
        guard let stored = try await credentials.baiduPanLibraryRoot(for: sourceID) else {
            return nil
        }
        let root = try await applicationDirectory()
        return Self.isValidLibraryRoot(stored.path, applicationRoot: root) ? stored : nil
    }

    /// 写入某个来源的片库根(`nil` = 清除,回到应用目录)。
    ///
    /// ⚠️ 清除是**落一个「没有」**,不是删键 —— 删键会让旧版兼容把它继承回来
    /// (见 `CredentialStore.baiduPanLibraryRoot(for:)`)。
    ///
    /// ⛔ 越界的路径**直接拒绝**,不存、也不静默改写成 root:
    /// 写出去一个和应用目录没关系的值,下次读要靠校验兜,多一条说不清的路。
    func setLibraryRoot(_ path: String?, for sourceID: UUID) async throws {
        guard let path else {
            try await credentials.saveBaiduPanLibraryRoot(nil, for: sourceID)
            return
        }
        let root = try await applicationDirectory()
        guard Self.isValidLibraryRoot(path, applicationRoot: root) else {
            throw BaiduPanError.configuration(
                "「\(path)」不在应用目录 \(root) 之内,不能设为片库根。")
        }
        try await credentials.saveBaiduPanLibraryRoot(.init(path: path), for: sourceID)
    }

    /// 片库根必须**落在应用目录之内**(或就是应用目录本身)。
    ///
    /// 判断用 `root + "/"` 前缀而不是 `hasPrefix(root)`:后者会把
    /// `/apps/LumaPlayerXX` 也算进 `/apps/LumaPlayer` 的范围里。
    /// ⛔ 那种路径第三方应用访问不到(`docs/BAIDU_PAN_API.md` §3),
    /// 设了就是个必然打不开的入口。
    static func isValidLibraryRoot(_ path: String, applicationRoot root: String) -> Bool {
        BaiduPanPath.isInside(path, applicationRoot: root)
    }

    /// 取设备码,准备走二维码授权。
    func startDeviceAuthorization() async throws -> BaiduPanDeviceCode {
        let configuration = try await appConfiguration()
        return try await client.deviceCode(clientID: configuration.appKey)
    }

    /// 轮询等用户在手机上确认。
    ///
    /// - 第一次请求前**先等一个 `interval`**:二维码刚画出来,用户还在掏手机,
    ///   立刻问一次必然是「还没确认」—— 白跑一次请求(配额很紧:
    ///   配额见 `docs/BAIDU_PAN_API.md` §7)。
    /// - 取消(token 已过期 / 用户关页)靠 `Task` 取消传播,不需要额外的信号。
    /// - 认不出来的 OAuth 错误码**继续等**,到点把最后一次错误带出来
    ///   (理由见 `BaiduPanError.isFatalOAuthCode`)。
    func awaitAuthorization(_ code: BaiduPanDeviceCode) async throws -> BaiduPanAccount {
        let configuration = try await appConfiguration()
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        var lastFailure: BaiduPanError?

        while true {
            try Task.checkCancellation()
            guard Date() < deadline else {
                if let lastFailure {
                    throw BaiduPanError.authorizationTimedOut(
                        lastFailure: lastFailure.userMessage)
                }
                throw BaiduPanError.deviceCodeExpired
            }
            try await Task.sleep(for: .seconds(Double(code.interval)))

            do {
                let bundle = try await client.token(
                    deviceCode: code.deviceCode,
                    clientID: configuration.appKey,
                    clientSecret: configuration.secretKey
                )
                try await credentials.saveBaiduPanToken(bundle)
                return try await loadAccount(accessToken: bundle.accessToken)
            } catch let error as BaiduPanError {
                if case .oauth(let oauthCode, _) = error,
                   BaiduPanError.isFatalOAuthCode(oauthCode) {
                    throw oauthCode == "access_denied" ? BaiduPanError.authorizationDenied : error
                }
                lastFailure = error
            }
        }
    }

    /// 解绑:删本地 token。**保留** AppKey / SecretKey / 目录名
    /// —— 重新扫码不该逼用户再填一遍密钥。
    func signOut() async throws {
        try await credentials.deleteBaiduPanToken()
        cachedAccount = nil
    }

    /// 重新读一次账号信息(昵称 / 会员档位)。
    func refreshAccount() async throws -> BaiduPanAccount {
        try await withToken { [client] token in
            try await client.accountInfo(accessToken: token)
        }
    }

    // MARK: - 内容

    /// 列出应用目录下的条目。目录在前、再按名字排 —— `order` 参数官方说
    /// 「按字符串处理」(`docs/BAIDU_PAN_API.md` §2.2),排序在客户端做更可控。
    func files() async throws -> [BaiduPanFile] {
        try await files(inDirectory: try await applicationDirectory())
    }

    func files(inDirectory directory: String) async throws -> [BaiduPanFile] {
        let entries = try await withToken { [client] token in
            try await client.list(directory: directory, accessToken: token)
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 删掉网盘上的一条文件或目录(`docs/BAIDU_PAN_API.md` §2.4)。
    ///
    /// ⚠️ **不可恢复**,而且删的是用户网盘里真东西,所以这里多两道闸:
    ///
    /// 路径必须**严格落在**应用目录之内。⛔ 不能直接信
    /// `BaiduPanPath.isInside`:它对「路径**等于**应用目录根」也返回 true,
    /// 只靠它就能一键删掉整个 `/apps/{应用目录名}`。
    ///
    /// ⚠️ 「删掉的若是片库根,顺手清掉书签」这件事**不在这里**:片库根按**来源**存,
    /// 这个 actor 不知道有哪些来源 —— 由调用方(`FileSourceViewModel.delete`)处置。
    ///
    /// 走 `withToken`:token 失效时它会刷新后重试一次。删除**不是幂等**操作,
    /// 但这里的重试只发生在「服务端说 token 失效」的码上 —— 那种情况下第一次
    /// 请求确实没有生效,重发一次是对的,不会把已经删掉的东西再删一遍。
    func deleteFile(at path: String) async throws {
        let root = try await applicationDirectory()
        guard BaiduPanPath.isInside(path, applicationRoot: root), path != root else {
            throw BaiduPanError.configuration(
                "「\(path)」不在应用目录 \(root) 之内,不能删除。")
        }
        try await withToken { [client] token in
            try await client.delete(path: path, accessToken: token)
        }
    }

    /// 批量改名(`docs/BAIDU_PAN_API.md` §2.5)。
    ///
    /// - Returns: 逐条结果,按提交顺序与入参一一对应(顺序语义见 §2.7 待实测第 3 条)。
    ///
    /// ⚠️ 两道闸(改的是用户网盘里的真东西,与删除同一级别):
    /// 1. 每条 `path` 必须**严格落在应用目录之内**,且⛔ 不能是应用目录根本身
    ///    (`isInside` 对「路径等于根」也返回 true,只靠它就能把 `/apps/{应用目录名}`
    ///    整个改掉,整个片库瞬间失联);
    /// 2. 新名非空、且不含 `/` —— rename 只改最后一段,带 `/` 说明调用方搞错了语义。
    ///
    /// 分片只为兜住「一次能放几条」这个**未实测**的上限(保守取 50,§2.7 第 1 条)。
    /// ⛔ 分片**不跨层级**:怎么分批、按什么顺序提交由 `BaiduPanRenameExecutor` 决定,
    ///   这里只管「同批的多条一起送」。
    func rename(
        _ operations: [BaiduPanRenameOperation]
    ) async throws -> [BaiduPanFileManagerResponse.Info] {
        guard !operations.isEmpty else { return [] }
        let root = try await applicationDirectory()
        for operation in operations {
            guard BaiduPanPath.isInside(operation.path, applicationRoot: root),
                  operation.path != root else {
                throw BaiduPanError.configuration(
                    "「\(operation.path)」不在应用目录 \(root) 之内,不能改名。")
            }
            guard !operation.newName.isEmpty, !operation.newName.contains("/") else {
                throw BaiduPanError.configuration(
                    "「\(operation.newName)」不是合法的名字:rename 只改最后一段,不能带 /。")
            }
        }

        var results: [BaiduPanFileManagerResponse.Info] = []
        for chunk in operations.chunked(into: Self.renameBatchLimit) {
            let info = try await withToken { [client] token in
                try await client.rename(chunk, accessToken: token)
            }
            results.append(contentsOf: info)
        }
        return results
    }

    /// 一次 `opera=rename` 最多送几条。**未实测**(§2.7 第 1 条),取保守值。
    private static let renameBatchLimit = 50

    // MARK: - 播放

    /// 把一条文件变成可播的流。
    ///
    /// 步骤(顺序有意如此,**为了少发请求** —— 配额见 §7):
    /// 1. `multimedia?method=filemetas&dlink=1` 取直连地址(8 小时有效)与时长
    ///    —— ⛔ **不是** `file?method=meta`,那条路实测不给 `dlink`
    ///    (见 `BaiduPanEndpoint.fileMeta`);
    /// 2. 交 `BaiduPanPlaybackPlanner` 映射 + 过 `PlaybackDecisionEngine` 判定;
    /// 3. **只有判成转码**才去探 `method=streaming`(能提前问出
    ///    `133` 要看广告 / `-6` token 失效 / `31347` 片子太长,
    ///    `docs/BAIDU_PAN_API.md` §2.3)。
    func playbackSelection(for file: BaiduPanFile) async throws -> BaiduPanStreamSelection {
        guard file.kind.isPlayable else {
            throw BaiduPanError.playbackUnsupported(
                "「\(file.name)」不是音视频文件,百度不会给它播放流。")
        }
        let type: BaiduPanStreamType = file.kind == .audio ? .audio : .video
        // 百度没有会话上报,这个 id 只喂判定表与日志,不会发给任何人
        let playSessionID = UUID().uuidString

        return try await withToken { [client] token in
            let meta = try await client.meta(fsID: file.fsID, accessToken: token)
            guard let rawDlink = meta.dlink, !rawDlink.isEmpty else {
                throw BaiduPanError.playbackUnsupported(
                    "百度没有给「\(file.name)」返回下载地址,这个文件没法直连播放。")
            }
            guard let directStreamURL = Self.appendingAccessToken(to: rawDlink, token: token) else {
                throw BaiduPanError.configuration("百度给的下载地址无法解析。")
            }
            guard let streamingURL = BaiduPanEndpoint.streaming(
                accessToken: token, path: file.path, type: type,
                probeOnly: false, adToken: nil
            ).url else {
                throw BaiduPanError.configuration("播放流地址构造失败。")
            }

            let selection = try BaiduPanPlaybackPlanner.selection(
                file: file,
                directStreamURL: directStreamURL,
                streamingURL: streamingURL,
                durationSeconds: meta.durationSeconds,
                playSessionID: playSessionID
            )

            if selection.route == .transcode {
                // ⛔ 探失败就**不要**建流:把 `133`/`31347` 之类的原话带出来,
                // 比让播放内核拿一条转不了的流报一个底层错误有用得多。
                if let failure = try await client.probeStreaming(
                    path: file.path, type: type, accessToken: token) {
                    throw failure
                }
            }
            return selection
        }
    }

    // MARK: - 封面

    /// 一次批量换出的元信息:下载地址 + 时长(失败的不在结果里)。
    ///
    /// ## 为什么必须批量
    ///
    /// 配额见 §7(`docs/BAIDU_PAN_API.md`),
    /// 逐个文件取会把配额瞬间烧光 —— 一个目录只发一次请求是这个功能
    /// 能不能用的前提。分片只为兜住接口对 `fsids` 长度的限制。
    ///
    /// ## 为什么封面与视频**同一批**取
    ///
    /// `filemetas` 本来就带 `needmedia=1`(`BaiduPanEndpoint.fileMeta`),
    /// 一条视频的 `duration` 与一张封面的 `dlink` 是同一个响应的两份字段。
    /// 分开取等于为了时长再发一遍请求 —— 而这批 id 通常远小于
    /// `metaBatchLimit`,合并之后请求数不变。
    /// ⚠️ 代价说清楚:一屏视频 + 封面超过 `metaBatchLimit` 时会多分一片,
    /// 那是「拿到时长」换来的额外请求,不是白拿的。
    ///
    /// ## 为什么失败不抛
    ///
    /// 封面与时长都是**锦上添花**:取不到就让那张卡降级成图标卡 / 不显示时长,
    /// ⛔ 不能让一次附加请求把整页内容挡在错误页后面。这与
    /// `Components/PosterImage.swift` 对图片加载失败的既有处置一致
    /// (留占位图,不弹窗、不重试风暴)。取不到的原因由「有没有这个值」体现,
    /// 不另记日志。
    struct MetaInfo: Sendable, Equatable {
        /// `fs_id` → 带 `access_token` 的下载地址(`dlink`)
        var downloadURLs: [UInt64: URL] = [:]
        /// `fs_id` → 时长(秒)。只有视频 / 音频条目才有
        var durations: [UInt64: Double] = [:]
    }

    func metaInfo(for fsIDs: [UInt64]) async -> MetaInfo {
        guard !fsIDs.isEmpty else { return MetaInfo() }
        var result = MetaInfo()
        for chunk in fsIDs.chunked(into: Self.metaBatchLimit) {
            let entries: [(fsID: UInt64, url: URL?, duration: Double?)]
            do {
                entries = try await withToken { [client] token in
                    let entries = try await client.metas(fsIDs: chunk, accessToken: token)
                    // `dlink` 必须在**这一趟的 token** 下追加凭据:刷新过的话
                    // 闭包外再取一次凭据是另一份值,拼出来的地址签名对不上。
                    return entries.compactMap { entry in
                        guard let fsID = entry.fsID else { return nil }
                        let url = entry.dlink.flatMap { raw -> URL? in
                            guard !raw.isEmpty else { return nil }
                            return Self.appendingAccessToken(to: raw, token: token)
                        }
                        return (fsID, url, entry.durationSeconds)
                    }
                }
            } catch {
                continue   // 这一片取不到就跳过(见上面的「失败不抛」)
            }
            for entry in entries {
                if let url = entry.url { result.downloadURLs[entry.fsID] = url }
                if let duration = entry.duration, duration > 0 {
                    result.durations[entry.fsID] = duration
                }
            }
        }
        return result
    }

    /// 一次 `filemetas` 最多带多少个 `fs_id`。官方未给明确上限,取常见实现的值。
    private static let metaBatchLimit = 100

    // MARK: - 内部:token

    /// 带 token 执行一次操作,并把「服务端说 token 失效」处置掉。
    ///
    /// 分两层:
    /// 1. 本地判过期(`expiresAt` 提前 5 分钟)→ 先刷新;
    /// 2. 本地没判出来而服务端回了需要刷新的错误码 → **再刷新一次并重试一次**。
    ///    第 2 条是必要的:token 可能被别处(另一个客户端 / 用户解除授权)弄失效,
    ///    本地时间戳看不出这一点。⛔ 只重试一次,不做退避循环。
    private func withToken<T>(_ operation: (String) async throws -> T) async throws -> T {
        let token = try await accessToken()
        do {
            return try await operation(token)
        } catch let error as BaiduPanError {
            guard case .server(let errno, _) = error,
                  BaiduPanErrno.requiresTokenRefresh.contains(errno) else { throw error }
            let refreshed = try await refreshingToken().accessToken
            return try await operation(refreshed)
        }
    }

    /// 拿一个可用的 access_token(本地判过期就地刷新)。
    private func accessToken() async throws -> String {
        guard let stored = try await credentials.baiduPanToken() else {
            throw BaiduPanError.notAuthorized("本地没有授权记录")
        }
        guard stored.needsRefresh() else { return stored.accessToken }
        return try await refreshingToken().accessToken
    }

    /// 强制刷新(不看本地过期时间)。单飞。
    private func refreshingToken() async throws -> BaiduPanTokenBundle {
        if let refreshTask {
            return try await refreshTask.value
        }
        let configuration = try await appConfiguration()
        guard let stored = try await credentials.baiduPanToken() else {
            throw BaiduPanError.notAuthorized("本地没有授权记录")
        }
        let client = self.client
        let credentials = self.credentials
        let task = Task<BaiduPanTokenBundle, any Error> {
            do {
                let fresh = try await client.refresh(
                    refreshToken: stored.refreshToken,
                    clientID: configuration.appKey,
                    clientSecret: configuration.secretKey
                )
                // ★ 必须落盘:refresh_token 只能用一次,新的不存下来,
                //   下一次刷新拿旧值必挂(`docs/BAIDU_PAN_API.md` §6)
                try await credentials.saveBaiduPanToken(fresh)
                return fresh
            } catch {
                // ★ 刷新失败 → 旧的 refresh_token 已经作废,清掉并要求重新授权。
                //   ⛔ 绝不拿旧 refresh_token 循环重试(那只会反复作废)。
                var cleanupNote = ""
                do {
                    try await credentials.deleteBaiduPanToken()
                } catch {
                    cleanupNote = "(本地授权记录清除失败:\(error))"
                }
                throw BaiduPanError.notAuthorized("刷新失败:\(Self.describe(error))\(cleanupNote)")
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func loadAccount(accessToken: String) async throws -> BaiduPanAccount {
        let account = try await client.accountInfo(accessToken: accessToken)
        cachedAccount = account
        return account
    }

    // MARK: - 内部:小工具

    /// `dlink` 必须**原样保留**它自己的查询串,只追加 `access_token`。
    ///
    /// ⛔ 不走 `URLComponents.queryItems` 再拼回去:那会把原有参数重新编码一遍
    /// (实测 `%2B` → `+`),而 `docs/BAIDU_PAN_API.md` §5 明说签名一旦对不上
    /// 就是 `31362 签名错误` —— 重新编码与截断是同一类风险。这里只在末尾追加。
    static func appendingAccessToken(to rawDlink: String, token: String) -> URL? {
        let separator = rawDlink.contains("?") ? "&" : "?"
        let encoded = BaiduPanEndpoint.encode(token) ?? token
        return URL(string: rawDlink + separator + "access_token=" + encoded)
    }

    /// 应用目录名规范化:去掉用户可能粘进来的前后斜杠与空白。
    private func normalizedFolderName(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private static func describe(_ error: any Error) -> String {
        (error as? BaiduPanError)?.userMessage ?? "\(error)"
    }
}

/// 按固定大小切段(百度 `filemetas` 的 `fsids` 长度限制用)。
private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
