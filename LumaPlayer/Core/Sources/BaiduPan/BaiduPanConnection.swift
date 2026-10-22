import Foundation

/// 百度网盘源的连接:授权状态机 + 自动刷新 + 内容读取。
///
/// 与 `ServerConnection` 不同:全 App 只有一份(一个开放平台应用、一次授权);token 在查询串上;
/// 没有播放上报,写接口只有删除与改名。
///
/// `refresh_token` 刷新必须单飞(`docs/BAIDU_PAN_API.md` §6):只能用一次,新值必须落盘;
/// 刷新失败旧值也作废 → 重新授权,⛔ 不得用旧值循环重试;同一应用再申请 token 会让前一个失效。
/// 所以并发调用方 await 同一个 `refreshTask`。
actor BaiduPanConnection {

    private let credentials: CredentialStore
    private let client: BaiduPanAPIClient
    private var refreshTask: Task<BaiduPanTokenBundle, any Error>?
    /// 只作展示的快照,不落盘
    private var cachedAccount: BaiduPanAccount?

    init(credentials: CredentialStore, client: BaiduPanAPIClient = BaiduPanAPIClient()) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: - 配置与授权状态

    /// 只读凭据文件,不发请求;token 是否有效由第一次真正的请求回答。配置不全返回 `.unconfigured`(是一屏,不是错误)。
    func authorization() async throws -> BaiduPanAuthorization {
        guard let configuration = try? await appConfiguration() else {
            return .unconfigured
        }
        guard try await credentials.baiduPanToken() != nil else {
            return .needsAuthorization(folderName: configuration.folderName)
        }
        return .authorized(account: cachedAccount)
    }

    /// 缺任一项都抛具体原因,UI 直接显示
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

    /// - Returns: 已有片库根是否失效。由调用方清各来源的片库根(片库根按来源存,这里不知道有哪些来源)。
    @discardableResult
    func saveConfiguration(appKey: String, secretKey: String, folderName: String) async throws -> Bool {
        let previous = try? await credentials.baiduPanAppConfiguration()
        let next = CredentialStore.BaiduPanAppConfiguration(
            appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            folderName: normalizedFolderName(folderName)
        )
        try await credentials.saveBaiduPanAppConfiguration(next)

        // 只改目录名不作废 token(token 只与密钥绑定),免得为改笔误再扫码
        guard previous?.appKey != next.appKey || previous?.secretKey != next.secretKey else {
            return previous?.folderName != next.folderName
        }
        // 换了密钥 = 换了应用,token 作废
        try await credentials.deleteBaiduPanToken()
        cachedAccount = nil
        return true
    }

    /// `/apps/{应用目录名}`,第三方应用能访问的根(`docs/BAIDU_PAN_API.md` §3)
    func applicationDirectory() async throws -> String {
        let configuration = try await appConfiguration()
        return "/apps/\(normalizedFolderName(configuration.folderName))"
    }

    // MARK: - 片库根

    /// nil = 没设,用应用目录。每次读都重新校验(目录名可能改过);校验不过当作没设,不报错。
    func libraryRoot(for sourceID: UUID) async throws -> BaiduPanLibraryRoot? {
        guard let stored = try await credentials.baiduPanLibraryRoot(for: sourceID) else {
            return nil
        }
        let root = try await applicationDirectory()
        return Self.isValidLibraryRoot(stored.path, applicationRoot: root) ? stored : nil
    }

    /// `nil` = 清除。清除是落一个「没有」而不是删键,删键会被兼容逻辑继承回来
    /// (见 `CredentialStore.baiduPanLibraryRoot(for:)`)。越界路径直接拒绝,不改写成 root。
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

    static func isValidLibraryRoot(_ path: String, applicationRoot root: String) -> Bool {
        BaiduPanPath.isInside(path, applicationRoot: root)
    }

    func startDeviceAuthorization() async throws -> BaiduPanDeviceCode {
        let configuration = try await appConfiguration()
        return try await client.deviceCode(clientID: configuration.appKey)
    }

    /// 轮询等用户在手机上确认。第一次请求前先等一个 `interval`,省一次必然「未确认」的请求
    /// (配额,`docs/BAIDU_PAN_API.md` §7)。取消靠 `Task` 取消传播。
    /// 认不出的 OAuth 错误码继续等,超时时带出最后一次错误(见 `BaiduPanError.isFatalOAuthCode`)。
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

    /// 只删 token,保留密钥与目录名
    func signOut() async throws {
        try await credentials.deleteBaiduPanToken()
        cachedAccount = nil
    }

    func refreshAccount() async throws -> BaiduPanAccount {
        try await withToken { [client] token in
            try await client.accountInfo(accessToken: token)
        }
    }

    // MARK: - 内容

    /// 目录在前、再按名字排;排序在客户端做(`docs/BAIDU_PAN_API.md` §2.2)
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

    /// 删除网盘条目,不可恢复(`docs/BAIDU_PAN_API.md` §2.4)。
    ///
    /// 路径必须严格在应用目录之内:⛔ 不能只靠 `isInside`,它对应用目录根本身也返回 true。
    /// 删的若是片库根,清书签由调用方(`FileSourceViewModel.delete`)处理。
    /// `withToken` 的重试只发生在 token 失效码上,那时第一次请求没生效,不会重复删除。
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
    /// - Returns: 逐条结果,与入参顺序对应(顺序语义见 §2.7 第 3 条)。
    ///
    /// 同删除的闸:路径严格在应用目录内且不是根本身;新名非空且不含 `/`(rename 只改最后一段)。
    /// 分片只为兜住每次条数上限;怎么分批、按什么顺序提交由 `BaiduPanRenameExecutor` 决定。
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

    /// 未实测(§2.7 第 1 条),保守值
    private static let renameBatchLimit = 50

    // MARK: - 播放

    /// 顺序为少发请求而定(配额 §7):
    /// 1. `filemetas&dlink=1` 取直连地址(8 小时有效)与时长;⛔ 不用 `file?method=meta`,它不给 `dlink`;
    /// 2. `BaiduPanPlaybackPlanner` + `PlaybackDecisionEngine` 判定;
    /// 3. 只有判成转码才探 `method=streaming`,提前问出 `133` / `-6` / `31347`(`docs/BAIDU_PAN_API.md` §2.3)。
    func playbackSelection(for file: BaiduPanFile) async throws -> BaiduPanStreamSelection {
        guard file.kind.isPlayable else {
            throw BaiduPanError.playbackUnsupported(
                "「\(file.name)」不是音视频文件,百度不会给它播放流。")
        }
        let type: BaiduPanStreamType = file.kind == .audio ? .audio : .video
        // 只用于判定与日志,不发给服务端
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
                // 探失败就不建流,把百度原话带出来
                if let failure = try await client.probeStreaming(
                    path: file.path, type: type, accessToken: token) {
                    throw failure
                }
            }
            return selection
        }
    }

    // MARK: - 封面

    /// 批量取的下载地址 + 时长,失败的不在结果里。
    ///
    /// 必须批量:逐个取会烧光配额(`docs/BAIDU_PAN_API.md` §7)。封面与视频同一批取,
    /// 因为 `filemetas` 带 `needmedia=1`,时长与 `dlink` 在同一个响应里。
    /// 失败不抛:封面与时长只是锦上添花,取不到就降级(同 `PosterImage`),不挡整页。
    struct MetaInfo: Sendable, Equatable {
        /// `fs_id` → 已带 `access_token` 的 `dlink`
        var downloadURLs: [UInt64: URL] = [:]
        /// `fs_id` → 秒,只有音视频条目有
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
                    // 必须用这一趟的 token 追加,刷新过的话闭包外的 token 是另一份
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
                continue   // 失败不抛
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

    /// 一次 `filemetas` 的 `fs_id` 数上限;官方未给,取常见实现的值
    private static let metaBatchLimit = 100

    // MARK: - 内部:token

    /// 本地判过期先刷新;服务端回了需刷新的错误码(token 可能被别处作废)再刷新并重试一次。⛔ 只重试一次。
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

    private func accessToken() async throws -> String {
        guard let stored = try await credentials.baiduPanToken() else {
            throw BaiduPanError.notAuthorized("本地没有授权记录")
        }
        guard stored.needsRefresh() else { return stored.accessToken }
        return try await refreshingToken().accessToken
    }

    /// 强制刷新,单飞
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
                // 必须落盘新值,refresh_token 只能用一次(§6)
                try await credentials.saveBaiduPanToken(fresh)
                return fresh
            } catch {
                // 刷新失败旧值已作废:清掉并要求重新授权,⛔ 不重试
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

    /// 原样保留 `dlink` 的查询串,只在末尾追加 `access_token`。⛔ 不走 `URLComponents.queryItems`:
    /// 会重新编码原有参数(`%2B` → `+`),导致 `31362 签名错误`(`docs/BAIDU_PAN_API.md` §5)。
    static func appendingAccessToken(to rawDlink: String, token: String) -> URL? {
        let separator = rawDlink.contains("?") ? "&" : "?"
        let encoded = BaiduPanEndpoint.encode(token) ?? token
        return URL(string: rawDlink + separator + "access_token=" + encoded)
    }

    /// 去掉前后斜杠与空白
    private func normalizedFolderName(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private static func describe(_ error: any Error) -> String {
        (error as? BaiduPanError)?.userMessage ?? "\(error)"
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
