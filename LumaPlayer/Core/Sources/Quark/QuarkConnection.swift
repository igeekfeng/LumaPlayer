import Foundation

/// 夸克网盘源的连接:登录态 + 内容读取 + 取直链。
///
/// 与另外两家网盘的差别:
/// - **扫码四步**(§4):拿二维码图片 → 用户在手机确认 → 轮询 `/oauth/code` 换授权码 → 换 token。
///   没有独立的「状态查询」端点,轮询就是反复调 `/oauth/code`,未确认时它回 `errno 11003`。
/// - **token 会轮换**:`refresh_token` 每次刷新换新的,必须落盘(§3);刷新失败就回扫码屏。
/// - **没有路径概念**:TV 端只给 fid 树(§5.1),所以这里维护一份「虚拟路径 → fid」索引,
///   让上层继续按路径串起续播 / 隐藏 / 刮削缓存(见 `QuarkPath`)。
/// - **只有读能力**:TV 端不支持建目录 / 改名 / 删除 / 移动(§9),本类型因此没有写接口。
/// - **串行限速**:间隔 ≥ 500ms,由 `QuarkAPIClient.QuarkRateLimiter` 保证(§5)。
actor QuarkConnection {

    private let credentials: CredentialStore
    private let client: QuarkAPIClient
    /// 只作展示的快照,不落盘
    private var cachedAccount: QuarkAccount?
    /// 正在扫码,防止两处同时开(第二张二维码会让第一张作废)
    private var isAuthorizing = false
    /// 刷新的单飞任务:并发调用方 await 同一个,避免同一次失效刷两遍
    /// (夸克的 `refresh_token` 会被轮换,两次并发刷新会有一个拿到已作废的值)
    private var refreshTask: Task<QuarkCredential, any Error>?
    /// 虚拟路径 → `fid` 的内存索引。
    ///
    /// 列过的目录顺手记住每一层;没列过的按路径从根走一遍(每层一次请求)。
    /// ⛔ 不落盘:落盘的那份(`BaiduPanDirectoryCache`)只存文件树,索引错了会把播放指到别的文件。
    private var pathIndex: [String: String] = [:]

    init(credentials: CredentialStore, client: QuarkAPIClient) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: - 登录态

    /// 只读凭据文件,不发请求。
    func authorization() async throws -> QuarkAuthorization {
        guard let credential = try await credentials.quarkCredential() else {
            return .needsAuthorization
        }
        return .authorized(credential: credential, account: cachedAccount)
    }

    func credential() async throws -> QuarkCredential {
        guard let credential = try await credentials.quarkCredential() else {
            throw QuarkError.notAuthorized
        }
        return credential
    }

    /// 当前设备 id。已经登录过就是凭据里那一份;否则生成一份 32 位 hex 并**先落盘**
    /// (它参与 `req_id` 与 token 刷新,⛔ 每次扫码都换新会白白作废之前的登录,§1)。
    func deviceID() async throws -> String {
        if let credential = try? await credentials.quarkCredential(), !credential.deviceID.isEmpty {
            return credential.deviceID
        }
        return try await credentials.quarkDeviceID { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    }

    /// 扫码第 1 步:拿二维码图片与 `query_token`。页面把 base64 直接显示出来(§4 第 1 步)。
    func startAuthorization(deviceID: String) async throws -> QuarkQRCodeSession {
        guard !isAuthorizing else { throw QuarkError.authorizationInProgress }
        isAuthorizing = true
        defer { isAuthorizing = false }
        return try await client.authorize(deviceID: deviceID)
    }

    /// 扫码第 2-4 步:轮询授权码,用户确认后换 token 并落盘(§4 第 3、4 步)。
    ///
    /// ⚠️ 轮询时 `errno 11003`(用户未确认)是**正常等待态**,不是失败。
    /// 只认两种失败:二维码过期(`11002`)、超时(本项目自己的上限)。
    /// ⛔ 不循环重试同一个授权码:换到 `11004` 就抛 `authorizationCodeInvalid`。
    func awaitAuthorization(
        _ session: QuarkQRCodeSession,
        deviceID: String,
        deadline: Date = Date().addingTimeInterval(QuarkQRCodeSession.validitySeconds)
    ) async throws -> QuarkAccount {
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw QuarkError.authorizationTimedOut }

            do {
                let code = try await client.code(queryToken: session.queryToken, deviceID: deviceID)
                let tokens = try await client.exchangeToken(
                    deviceID: deviceID, code: code, refreshToken: nil)
                let credential = QuarkCredential(
                    accessToken: tokens.access,
                    refreshToken: tokens.refresh,
                    deviceID: deviceID,
                    queryToken: session.queryToken)
                try await credentials.saveQuarkCredential(credential)
                pathIndex.removeAll()
                return try await loadAccount(credential)
            } catch QuarkError.server(let code, _) where code == QuarkCode.authorizationPending {
                // 继续等:隔一个轮询间隔再问(§4 第 2 步,参考实现是 2 秒)
                try await Task.sleep(for: QuarkPolicy.authorizationPollInterval)
                continue
            }
        }
    }

    /// 只删 token,保留片库根(重新登录后还在原目录)。
    func signOut() async throws {
        try await credentials.deleteQuarkCredential()
        cachedAccount = nil
        refreshTask?.cancel()
        refreshTask = nil
        pathIndex.removeAll()
    }

    /// 扫码成功后取一次昵称,供设置页展示。⛔ 不在启动时主动刷新(§7:最小调用原则)。
    private func loadAccount(_ credential: QuarkCredential) async throws -> QuarkAccount {
        let account = try await client.userInfo(
            accessToken: credential.accessToken, deviceID: credential.deviceID)
        cachedAccount = account
        return account
    }

    // MARK: - token 刷新(§3)

    /// 确保手上有一个**没被服务端判成无效**的 token。
    ///
    /// 夸克不给「提前刷新」的依据(`expires_in` 的语义没有一手证据,§8),所以照参考实现走
    /// 「请求失败触发」:业务请求撞上 `11001` 时刷一次、重试一次,⛔ 不另起定时器。
    /// 刷新是单飞的:并发调用方 await 同一个任务。
    private func refreshed() async throws -> QuarkCredential {
        if let refreshTask { return try await refreshTask.value }
        let current = try await credential()
        let task = Task { [client, credentials] () -> QuarkCredential in
            let tokens = try await client.exchangeToken(
                deviceID: current.deviceID, code: nil, refreshToken: current.refreshToken)
            let next = QuarkCredential(
                accessToken: tokens.access,
                refreshToken: tokens.refresh,
                deviceID: current.deviceID,
                queryToken: current.queryToken)
            // ⚠️ `refresh_token` 已轮换:新值必须落盘,否则下次刷新用的是作废的旧值(§3)
            try await credentials.saveQuarkCredential(next)
            return next
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: - 片库根

    func libraryRoot(for sourceID: UUID) async throws -> QuarkLibraryRoot? {
        try await credentials.quarkLibraryRoot(for: sourceID)
    }

    /// `nil` = 清空,回到网盘根。
    func setLibraryRoot(_ root: QuarkLibraryRoot?, for sourceID: UUID) async throws {
        try await credentials.saveQuarkLibraryRoot(root, for: sourceID)
    }

    // MARK: - 内容

    /// 列一层(**单页**,按需翻)。浏览页走它。
    ///
    /// - Parameter directory: 虚拟路径,`"/"` 是网盘根。内部换成 `fid` 再请求。
    func listPage(
        in directory: String,
        pageIndex: Int,
        pageSize: Int = QuarkPolicy.pageSize
    ) async throws -> QuarkDirectoryPage {
        let normalized = QuarkPath.normalized(directory)
        let parentFid = try await fid(forPath: normalized)
        let page = try await withValidToken { credential in
            try await client.list(
                parentFid: parentFid,
                accessToken: credential.accessToken,
                deviceID: credential.deviceID,
                pageIndex: pageIndex,
                pageSize: pageSize)
        }
        // 顺手记住这一层子项:进子目录 / 起播就不用再按路径走一遍
        for entry in page.files {
            pathIndex[QuarkPath.child(entry.name, of: normalized)] = entry.fid
        }
        return page
    }

    /// 一次列完整个目录(自动翻页)。
    ///
    /// ⛔ 只给「必须拿到整层」的场景用(季文件夹的分集清单、目录选择器、按路径解析 fid)。
    /// 浏览页走 `listPage` 按需翻(夸克按次记账且要串行,§5)。
    func files(in directory: String) async throws -> [QuarkFileEntry] {
        let normalized = QuarkPath.normalized(directory)
        let parentFid = try await fid(forPath: normalized)
        return try await allEntries(parentFid: parentFid, path: normalized)
    }

    /// 按 `fid` 翻完整个目录。⛔ 不走 `fid(forPath:)`,所以不会递归。
    private func allEntries(parentFid: String, path: String) async throws -> [QuarkFileEntry] {
        var entries: [QuarkFileEntry] = []
        var pageIndex = 0
        for _ in 0..<Self.maxPages {
            let page = try await withValidToken { credential in
                try await client.list(
                    parentFid: parentFid,
                    accessToken: credential.accessToken,
                    deviceID: credential.deviceID,
                    pageIndex: pageIndex,
                    pageSize: QuarkPolicy.pageSize)
            }
            entries.append(contentsOf: page.files)
            // 顺手记住这一层:进子目录 / 起播就不用再按路径走一遍
            for entry in page.files {
                pathIndex[QuarkPath.child(entry.name, of: path)] = entry.fid
            }
            guard page.hasMore else { break }
            pageIndex = page.nextPageIndex
        }
        return entries
    }

    /// 防御服务端忽略分页一直返满页导致死循环
    private static let maxPages = 20

    /// 虚拟路径 → `fid`。先查内存索引,没有就按路径从根走一遍(`docs/QUARK_API.md` §5:只有 fid 树)。
    ///
    /// - Note: 走路径是**每层一次请求**(有 500ms 间隔)。浏览过的目录都在索引里,
    ///   所以正常浏览不额外花请求;只有「冷启动直接播某条续播记录」会走这条路。
    func fid(forPath path: String) async throws -> String {
        let normalized = QuarkPath.normalized(path)
        if normalized == QuarkPath.root { return QuarkEndpoint.rootFid }
        if let cached = pathIndex[normalized] { return cached }

        var currentPath = QuarkPath.root
        var currentFid = QuarkEndpoint.rootFid
        let components = normalized.split(separator: "/").map(String.init)
        for component in components {
            let nextPath = QuarkPath.child(component, of: currentPath)
            if let cached = pathIndex[nextPath] {
                currentFid = cached
                currentPath = nextPath
                continue
            }
            // ⚠️ 必须翻完这一层:目标目录可能在第 2 页之后,⛔ 只看第一页会误判成「不存在」
            _ = try await allEntries(parentFid: currentFid, path: currentPath)
            guard let match = pathIndex[nextPath] else {
                throw QuarkError.directoryNotFound(path: nextPath)
            }
            currentFid = match
            currentPath = nextPath
        }
        return currentFid
    }

    // MARK: - 播放

    /// 取一条可播放的直链(§6.1 原文件直链)。
    ///
    /// 只走 `method=download`:转码直链(`method=streaming`)不是原画、还要额外兜
    /// 「取不到 url 就回退」的分支(§6.2),本项目不实现第二条路径。
    ///
    /// - Parameter filePath: 虚拟路径。⛔ 不收 `fsID`:它是路径派生出来的哈希,反推不回 fid。
    ///
    /// ⛔ 直链是**死 URL**:有效期未知,过期就 403,没有刷新机制(§8)。
    /// 调用方(播放页重试)会重新调本方法拿新链。
    func playbackLink(forPath filePath: String) async throws -> QuarkDownloadLink {
        let fid = try await fid(forPath: filePath)
        return try await withValidToken { credential in
            try await client.download(
                fid: fid, accessToken: credential.accessToken, deviceID: credential.deviceID)
        }
    }

    // MARK: - token 失效重试

    /// 跑一次业务请求;撞上「access_token 无效」就刷新并**重试一次**(§3)。
    ///
    /// ⚠️ 只重试一次:刷新过还失败就抛,⛔ 不循环(参考实现同样只重试一次)。
    /// ⚠️ 只对 `11001` 生效:`10001` 是签名 / 公参被拒(实测),刷新 token 解决不了它。
    private func withValidToken<T>(
        _ body: (QuarkCredential) async throws -> T
    ) async throws -> T {
        let credential = try await credential()
        do {
            return try await body(credential)
        } catch QuarkError.server(let code, _) where code == QuarkCode.tokenInvalid {
            let refreshed = try await refreshed()
            return try await body(refreshed)
        }
    }
}

/// 夸克源的授权状态。与 115 同形:没有「应用配置不全」这一档。
enum QuarkAuthorization: Sendable, Equatable {
    case needsAuthorization
    case authorized(credential: QuarkCredential, account: QuarkAccount?)

    var account: QuarkAccount? {
        if case .authorized(_, let account) = self { return account }
        return nil
    }

    var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }
}
