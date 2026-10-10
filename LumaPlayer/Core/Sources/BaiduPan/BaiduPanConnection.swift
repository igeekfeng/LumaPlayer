import Foundation

/// 百度网盘源的连接(actor):授权状态机 + 自动刷新 + 内容读取。
///
/// ## 与 `ServerConnection` 的对应关系
///
/// 形状照 `ServerConnection`(actor、每台一个、token 不共享),但语义完全不同:
/// - **只有一份**:一个 App 对应开放平台上一个应用,一个用户授权一次
///   (不像 Emby 那样按服务器分);
/// - **token 在查询串上**,不在请求头;
/// - **没有播放上报**(§5.2),所以这个 actor 里没有任何写接口。
///
/// ## ★ `refresh_token` 单飞(文档 §3.4 的三条坑)
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
    func authorization() async throws -> BaiduPanAuthorization {
        let configuration = try await appConfiguration()
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

    func saveConfiguration(appKey: String, secretKey: String, folderName: String) async throws {
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
            // 目录名换了 → 旧片库根必然落在新应用目录之外,直接清掉
            // (不清也行:`libraryRoot()` 的前缀校验会兜住,但留着是垃圾)。
            if previous?.folderName != next.folderName {
                try? await credentials.deleteBaiduPanLibraryRoot()
            }
            return
        }
        // 换了应用(AppKey / SecretKey 变了)就是换了一套授权,token 必须一起作废
        try await credentials.deleteBaiduPanToken()
        try? await credentials.deleteBaiduPanLibraryRoot()
        cachedAccount = nil
    }

    /// 第三方应用能访问的根目录:`/apps/{应用目录名}`(文档 §2.1)。
    func applicationDirectory() async throws -> String {
        let configuration = try await appConfiguration()
        return "/apps/\(normalizedFolderName(configuration.folderName))"
    }

    // MARK: - 片库根

    /// 用户在应用目录**内部**选定的起点。nil = 就用应用目录本身。
    ///
    /// ⛔ 存下来的路径**每次读都要重新校验**:用户可能回头改了「应用目录名」
    /// (改完旧路径整个失效),也可能在网盘里把那个子目录删了。
    /// 校验不过时**静默回落**到应用目录 —— ⛔ 不报「配置损坏」:
    /// 比起让人卡在一页打不开的错误上,回到能用的起点更有用。
    func libraryRoot() async throws -> String? {
        guard let stored = try await credentials.baiduPanLibraryRoot() else { return nil }
        let root = try await applicationDirectory()
        guard Self.isValidLibraryRoot(stored.path, applicationRoot: root) else { return nil }
        return stored.path
    }

    /// 记下片库根。`nil` = 清除(回到应用目录)。
    func setLibraryRoot(_ path: String?) async throws {
        guard let path else {
            try await credentials.deleteBaiduPanLibraryRoot()
            return
        }
        let root = try await applicationDirectory()
        // ⛔ 越界的路径**直接拒绝**,不存、也不静默改写成 root:
        // 写出去一个和应用目录没关系的值,下次读要靠校验兜,多一条说不清的路。
        guard Self.isValidLibraryRoot(path, applicationRoot: root) else {
            throw BaiduPanError.configuration(
                "「\(path)」不在应用目录 \(root) 之内,不能设为片库根。")
        }
        try await credentials.saveBaiduPanLibraryRoot(.init(path: path))
    }

    /// 片库根必须**落在应用目录之内**(或就是应用目录本身)。
    ///
    /// 判断用 `root + "/"` 前缀而不是 `hasPrefix(root)`:后者会把
    /// `/apps/LumaPlayerXX` 也算进 `/apps/LumaPlayer` 的范围里。
    /// ⛔ 那种路径第三方应用访问不到(§2.1),设了就是个必然打不开的入口。
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
    ///   立刻问一次必然是「还没确认」—— 白跑一次请求(配额很紧)。
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
    /// 「按字符串处理」,排序在客户端做更可控。
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

    // MARK: - 播放

    /// 把一条文件变成可播的流。
    ///
    /// 步骤(顺序有意如此,**为了少发请求**):
    /// 1. `multimedia?method=filemetas&dlink=1` 取直连地址(8 小时有效)与时长
    ///    —— ⛔ **不是** `file?method=meta`,那条路实测不给 `dlink`(见 `BaiduPanEndpoint.fileMeta`);
    /// 2. 合成 `PlaybackInfo` 过 Rust 决策器 → 直接串流 / 转码;
    /// 3. **只有判成转码**才去探 `method=streaming`(能提前问出
    ///    `133` 要看广告 / `-6` token 失效 / `31347` 片子太长,§5.4)。
    func playbackSelection(for file: BaiduPanFile) async throws -> BaiduPanStreamSelection {
        guard file.kind.isPlayable else {
            throw BaiduPanError.playbackUnsupported(
                "「\(file.name)」不是音视频文件,百度不会给它播放流。")
        }
        let type: BaiduPanStreamType = file.kind == .audio ? .audio : .video
        // 百度没有会话上报(§5.2),这个 id 只喂决策器与日志,不会发给任何人
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
            let duration = meta.durationSeconds

            let decision = try BaiduPanPlaybackPlanner.decision(
                file: file,
                directStreamURL: directStreamURL,
                streamingURL: streamingURL,
                durationSeconds: duration,
                playSessionID: playSessionID
            )

            if decision.method == PlaybackMethod.transcode.rawValue {
                // ⛔ 探失败就**不要**建流:把 `133`/`31347` 之类的原话带出来,
                // 比让 AVPlayer 拿一条转不了的流报一个 `-11850` 有用得多。
                if let failure = try await client.probeStreaming(
                    path: file.path, type: type, accessToken: token) {
                    throw failure
                }
            }

            return try BaiduPanPlaybackPlanner.selection(
                file: file,
                decision: decision,
                directStreamURL: directStreamURL,
                streamingURL: streamingURL,
                durationSeconds: duration
            )
        }
    }

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
                //   下一次刷新拿旧值必挂(§3.4)
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

    /// `dlink` 必须**原样保留**它自己的查询串,只追加 `access_token`(§4.5 ②)。
    ///
    /// ⛔ 不走 `URLComponents.queryItems` 再拼回去:那会把原有参数重新编码一遍,
    /// 而文档明说「必须原样保留 dlink 的查询串,截断会报 `31362 签名错误`」——
    /// 重新编码与截断是同一类风险。这里只在末尾追加。
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
