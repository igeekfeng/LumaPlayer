import Foundation

/// 115 网盘源的连接:登录态 + 内容读取 + 取直链。
///
/// 与 `BaiduPanConnection` 的差别:
/// - **没有 token / 刷新**:115 的 Cookie 是长期凭据,没有刷新接口(`docs/PAN115_API.md` §2)。
///   Cookie 失效只有一个表现 —— 被踢下线或过期,那时只能重新扫码。
/// - **渠道**:换 Cookie 绑定在 `Pan115AuthorizationApp.default`(`tv`),与浏览器 Web 端分属不同
///   `ssoent` 组,避免互踢(§2.1.1)。前三步扫码仍走 `web`。
/// - **没有应用目录**:Cookie 能读整个网盘,片库根只是书签(见 `Pan115LibraryRoot`)。
/// - **限速是硬约束**:串行、间隔 ≥ 500ms(§6),由 `Pan115APIClient` 的 `Pan115RateLimiter` 保证。
/// - ⛔ **不主动探活**。`passportapi.115.com/.../check/sso` 会让同设备其它 Cookie 失效(§2.3),
///   而 Cookie 过期本来就会在第一次读盘时暴露(`errno 990001` / `40101035`)。
actor Pan115Connection {

    private let credentials: CredentialStore
    private let client: Pan115APIClient
    /// 只作展示的快照,不落盘
    private var cachedAccount: Pan115Account?
    /// 扫码会话进行中的标记,防止两处同时开扫码(第二次会踢掉第一次的二维码)
    private var isAuthorizing = false
    /// 路径 → `cid` 的内存索引。
    ///
    /// 115 的 `files` 只认 `cid`(§3),而浏览页、续播快照、剧集归属全都按路径串起来
    /// (`BaiduPanFile.path`、`BaiduPanPath.seriesDirectory`)。这里做一层映射,让上层继续用路径:
    /// 列过的目录顺手记住映射,没列过的用 `files/getid` 换一次(§6 限速,能省则省)。
    /// ⛔ 不落盘:映射错一位就会列到别人的目录,进程重启重列一次目录比这个便宜。
    private var directoryIndex: [String: String] = [:]

    /// `client` ⛔ 不给默认值:默认值会顺手造一个新的 `Pan115APIClient`,也就带一个新的
    /// `Pan115RateLimiter` —— 两套限速器各记各的间隔,全局 500 ms 串行立刻失效。
    /// 限速器必须全 App 共用一份,由组合根(`AppContainer`)注入。
    init(credentials: CredentialStore, client: Pan115APIClient) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: - 登录态

    /// 只读凭据文件,不发请求;Cookie 是否还有效由第一次真正的请求回答。
    func authorization() async throws -> Pan115Authorization {
        guard let credential = try await credentials.pan115Credential() else {
            return .needsAuthorization
        }
        return .authorized(credential: credential, account: cachedAccount)
    }

    func credential() async throws -> Pan115Credential {
        guard let credential = try await credentials.pan115Credential() else {
            throw Pan115Error.notAuthorized
        }
        return credential
    }

    /// 已存 Cookie 的渠道名(从 UID 中段 `ssoent` 反查,§2.1)。
    /// 只读凭据文件,不发请求;认不出 / 还没登录 / 读凭据失败都返回 nil。
    func authorizationChannel() async -> String? {
        let credential: Pan115Credential?
        do {
            credential = try await credentials.pan115Credential()
        } catch {
            return nil
        }
        guard let credential, let ssoent = credential.ssoent else { return nil }
        return Pan115AuthorizationApp.displayName(forSSOEnt: ssoent)
    }

    /// 扫码登录第 1 步:拿二维码内容。调用方把它渲染成二维码给用户扫。
    func startAuthorization() async throws -> Pan115QRCodeSession {
        guard !isAuthorizing else {
            throw Pan115Error.authorizationInProgress
        }
        isAuthorizing = true
        defer { isAuthorizing = false }
        return try await client.qrCodeToken()
    }

    /// 扫码登录第 2-4 步:轮询状态,用户确认后换 Cookie 并落盘。
    ///
    /// 轮询间隔由两处共同兜住:传输层 `Pan115RateLimiter` 保证任意两次请求 ≥ 500 ms,
    /// 这一层再加一个 `Pan115Policy.authorizationPollInterval` 的下限 —— 扫码接口是长轮询,
    /// 服务端状态没变时会把请求挂住;但它提前返回时,没有这个下限就会变成每秒两次的空转,
    /// 而 180 秒的窗口能攒出上百次请求(§6 的频控就是这么撞上的)。
    /// 超时按 `Pan115QRCodeSession.validitySeconds` 算 —— 那是**本项目自己定的**上限,
    /// 115 不给有效期(见该常量的注释)。
    func awaitAuthorization(
        _ session: Pan115QRCodeSession,
        deadline: Date = Date().addingTimeInterval(Pan115QRCodeSession.validitySeconds),
        app: Pan115AuthorizationApp = .default
    ) async throws -> Pan115Account {
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Pan115Error.authorizationTimedOut }

            let status = try await client.qrCodeStatus(session)
            switch status {
            case .waiting, .scanned:
                // 状态没变:等到下一个轮询点再问,⛔ 不立刻重发
                try await Task.sleep(for: Pan115Policy.authorizationPollInterval)
                continue
            case .allowed:
                let credential = try await client.qrCodeLogin(session, app: app)
                try await credentials.savePan115Credential(credential)
                // 换了账号,旧的路径 → cid 映射全部作废
                resetDirectoryIndex()
                return try await loadAccount(credential)
            case .expired:
                throw Pan115Error.qrCodeExpired
            case .canceled:
                throw Pan115Error.qrCodeCanceled
            case .unknown(let raw):
                throw Pan115Error.server(
                    code: raw, message: "扫码状态返回了没见过的值 \(raw)")
            }
        }
    }

    /// 只删 Cookie,保留各来源的片库根(重新登录后还在原目录)。
    func signOut() async throws {
        try await credentials.deletePan115Credential()
        cachedAccount = nil
        resetDirectoryIndex()
    }

    /// 扫码成功后取一次昵称/VIP,存进 `cachedAccount` 供 `authorization()` 展示。
    /// ⛔ 不要在启动时主动刷新:每多一次请求就多一分风控面(§6)。
    private func loadAccount(_ credential: Pan115Credential) async throws -> Pan115Account {
        let account = try await client.account(credential)
        cachedAccount = account
        return account
    }

    // MARK: - 片库根

    func libraryRoot(for sourceID: UUID) async throws -> Pan115LibraryRoot? {
        try await credentials.pan115LibraryRoot(for: sourceID)
    }

    /// `nil` = 清空,回到网盘根(`cid=0`)。
    func setLibraryRoot(_ root: Pan115LibraryRoot?, for sourceID: UUID) async throws {
        try await credentials.savePan115LibraryRoot(root, for: sourceID)
    }

    // MARK: - 内容

    /// 列目录。目录在前、再按名字排 —— 排序在客户端做,115 自己的顺序不可靠(§3)。
    ///
    /// - Parameter path: 从网盘根算起的路径,`"/"` 是根。内部换成 `cid` 再请求。
    ///
    /// ⚠️ 这是**列完整个目录**的版本(自动翻页,最多 `Pan115APIClient.maxPages` 页)。
    /// 浏览页按需翻页走 `listPage(in:offset:limit:)`。
    ///
    /// 同一路径的**在飞**请求合并成一次:缓存命中时前台与后台刷新会同时打到这里,
    /// 目录选择器连点两下也是。115 按次记账(§6),两发同内容的 `files` 纯属白花预算。
    /// ⛔ 只合并在飞的,不缓存结果 —— 缓存是上层(`FileSourceViewModel` + 落盘)的事。
    func files(in path: String) async throws -> [Pan115FileEntry] {
        let key = Self.normalizedPath(path)
        if let inFlight = inFlightFiles[key] {
            return try await inFlight.value
        }
        let task = Task { try await self.fetchFiles(in: key) }
        inFlightFiles[key] = task
        defer { inFlightFiles[key] = nil }
        return try await task.value
    }

    /// 正在列的目录(键是归一化路径)。请求一结束就摘掉。
    private var inFlightFiles: [String: Task<[Pan115FileEntry], any Error>] = [:]

    /// 列完整个目录(自动翻页)。
    private func fetchFiles(in path: String) async throws -> [Pan115FileEntry] {
        let credential = try await credential()
        let cid = try await directoryID(path: path)
        let entries = try await client.list(cid: cid, credential: credential)
        // 顺手记住这一层子目录的映射:进子目录时就不用再发 getid
        for entry in entries where entry.isDirectory {
            guard let id = entry.numericID.map(String.init) else { continue }
            directoryIndex[Self.childPath(entry.name, of: path)] = id
        }
        return entries
    }

    /// 列一页。浏览页按需翻页用这个,⛔ 不一次把整个目录拉完
    /// (115 的请求串行且两次之间至少隔 500 ms,§6)。
    ///
    /// - Parameter offset: 偏移量。⚠️ 必须用上一页返回的 `offset` + 本页条数推进,
    ///   ⛔ 不自行累加固定步长:服务端确认过的 offset 才是它认的位置
    ///   (aps 接口的文档明写 offset 越界会「相当于 offset=0,从头开始」,自行累加会静默回绕)。
    func listPage(
        in path: String,
        offset: Int,
        limit: Int
    ) async throws -> Pan115DirectoryPage {
        let normalized = Self.normalizedPath(path)
        let cid = try await directoryID(path: normalized)
        let credential = try await credential()
        let page = try await client.listPage(
            cid: cid, credential: credential, offset: offset, limit: limit)
        // 顺手记住这一层子目录的映射:进子目录时就不用再发 getid
        for entry in page.entries where entry.isDirectory {
            guard let id = entry.numericID.map(String.init) else { continue }
            directoryIndex[Self.childPath(entry.name, of: normalized)] = id
        }
        return Pan115DirectoryPage(
            entries: Self.sorted(page.entries),
            offset: page.offset,
            isOffsetHonored: page.isOffsetHonored,
            limit: page.limit,
            totalCount: page.totalCount,
            hasMore: page.hasMore
        )
    }

    /// 目录在前、再按名字排 —— 排序在客户端做,115 自己的顺序不可靠(§3)。
    private static func sorted(_ entries: [Pan115FileEntry]) -> [Pan115FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 路径换 `cid`(115 的 `files/getid?path=`,§3)。先查内存索引,没有才发请求。
    func directoryID(path: String) async throws -> String {
        let normalized = Self.normalizedPath(path)
        if normalized == Pan115LibraryRoot.root.path { return "0" }
        if let cached = directoryIndex[normalized] { return cached }
        let credential = try await credential()
        let cid = try await client.directoryID(path: normalized, credential: credential)
        directoryIndex[normalized] = cid
        return cid
    }

    /// 换 Cookie 后旧映射全部作废。
    private func resetDirectoryIndex() {
        directoryIndex.removeAll()
    }

    /// `"/影视"` + `"电影"` → `"/影视/电影"`;父路径是根时不产生双斜杠。
    static func childPath(_ name: String, of parent: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// 去掉尾部斜杠、空串归成 `/`,让索引键统一。
    static func normalizedPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }

    // MARK: - 删除

    /// 删一个文件或目录(115 → 回收站,§9)。
    ///
    /// - Parameter id: 文件 `fid` 或目录 `cid`。浏览页拿到的 `BaiduPanFile.fsID` 就是它,
    ///   ⛔ 不为删除再按路径换一次 id(多一次请求 = 多一次风控面)。
    ///
    /// ⚠️ 115 的删除是**移进回收站**,不允许并发、与还原互斥(§9):一次只删一条,
    /// 由全 App 共用的 `Pan115RateLimiter` 串行。
    /// ⛔ **失败不重试**:第一次可能已经生效,重发就是第二次删除,还多一次风控面。
    func deleteFile(id: String) async throws {
        guard !id.isEmpty else {
            throw Pan115Error.invalidRequest("这一条没有可用的文件 ID")
        }
        let credential = try await credential()
        do {
            try await client.delete(ids: [id], credential: credential)
        } catch let error as Pan115Error where error == .alreadyDeleted {
            // 文件已经不在网盘里(别处删过 / 上一次其实生效了)。目标状态已经达成:
            // ⛔ 不重发也不报错,交给调用方照常做本地清理。
        }
        // 删掉的是目录时,它的 path → cid 映射随之失效;⛔ 留着会让同路径的下一层列到旧目录。
        directoryIndex = directoryIndex.filter { $0.value != id }
    }

    // MARK: - 播放

    /// 取一条可播放的直链。
    ///
    /// 115 只有一条可用路径:原文件直链(§4.1)。转码 m3u8(§4.2)要求 web Cookie + 绑定取链时的 UA,
    /// 且会消耗 115 的转码资源,本项目不用 —— 直链交给 libmpv 直接播就够了。
    ///
    /// - Parameter pickCode: 列目录时缓存的 `pc`。⛔ 不放进 `BaiduPanFile`:
    ///   那个类型是文件树来源的通用形状,只有 115 需要 `pick_code`。
    ///
    /// ⛔ 直链是**死 URL**:`t` 参数到期就 403,没有刷新机制。调用方在播放失败时要重新取一次。
    ///
    /// 同一个 `pickCode` 的在飞请求合并成一次:连点两集、连点重试都会并发打到这里,
    /// 而 115 会把重复取链记成「无意义调用」(§6)。合并只作用于**同时进行中**的请求,
    /// ⛔ 不缓存结果 —— 重试要拿到新链,复用旧链只会再 403 一次。
    func playbackLink(pickCode: String) async throws -> Pan115DownloadLink {
        guard !pickCode.isEmpty else {
            throw Pan115Error.pickCodeMissing("pick_code 为空")
        }
        if let inFlight = inFlightLinks[pickCode] {
            return try await inFlight.value
        }
        let task = Task { try await self.fetchPlaybackLink(pickCode: pickCode) }
        inFlightLinks[pickCode] = task
        defer { inFlightLinks[pickCode] = nil }
        return try await task.value
    }

    /// 正在取链的 `pickCode`。值只在请求进行中存在,请求一结束就摘掉。
    private var inFlightLinks: [String: Task<Pan115DownloadLink, any Error>] = [:]

    private func fetchPlaybackLink(pickCode: String) async throws -> Pan115DownloadLink {
        let credential = try await credential()
        return try await client.downloadURL(pickCode: pickCode, credential: credential)
    }
}

/// 115 源的授权状态。比百度简单:没有「应用配置不全」这一档。
enum Pan115Authorization: Sendable, Equatable {
    /// 还没登录过,或已解绑
    case needsAuthorization
    case authorized(credential: Pan115Credential, account: Pan115Account?)

    var account: Pan115Account? {
        if case .authorized(_, let account) = self { return account }
        return nil
    }

    var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }
}
