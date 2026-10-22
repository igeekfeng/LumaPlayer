import Foundation

/// 登录流程的失败原因。与 `EmbyAPIError` 分开:登录请求本身的 401 是「密码错」,不是「token 失效」,
/// 不能提示「登录已过期」(API_CONTRACT.md 2.5)。
enum ServerLoginError: Error, Equatable {
    /// `/emby` 与根两个前缀(及允许的 http 回退)都拿不到公开信息(API_CONTRACT.md 1.4)
    case unreachable(host: String)
    /// 401:用户名或密码错误。不清 token、不提示「重新登录」
    case invalidCredentials
    /// 登录成功,但用鉴权请求验证访问权限时失败
    case accessDenied(EmbyAPIError)
    case api(EmbyAPIError)
    /// token 没写进凭据文件
    case credentialFailure
}

/// http 回退成功时 `baseURL` 的 scheme 是 http(API_CONTRACT.md 1.4)。
struct ServerProbeResult: Sendable, Equatable {
    let baseURL: URL
    let compatibility: ServerCompatibility
    /// 端点没给就是 nil
    let serverID: String?
}

struct ServerLoginResult: Sendable, Equatable {
    /// 已回填 serverID / serverVersion / userID / username / apiPathPrefix
    let profile: ServerProfile
    let compatibility: ServerCompatibility
}

/// 单台服务器的连接、探测与登录。一台一个实例、一个 `EmbyAPIClient`,token 不共享,
/// 「一台 401 不影响另一台」是结构上成立的。
actor ServerConnection {
    private var profile: ServerProfile
    private let credentials: CredentialStore
    private let client: EmbyAPIClient
    /// nil = 不缓存(单测默认),生产由 `AppContainer` 注入共享实例
    private let responseCache: EmbyResponseCache?
    /// scheme 是规范化算法补的(API_CONTRACT.md 1.3);只有 true 才允许局域网 http 回退(1.4)
    private let schemeWasInferred: Bool
    /// 在途的静默重登。并发的 401 / 缺 token 共用一次,不各打一遍 `AuthenticateByName`
    private var reauthentication: Task<Void, Error>?

    init(
        profile: ServerProfile,
        credentials: CredentialStore,
        schemeWasInferred: Bool = false,
        session: URLSession = .shared,
        responseCache: EmbyResponseCache? = nil
    ) {
        self.profile = profile
        self.credentials = credentials
        self.responseCache = responseCache
        self.schemeWasInferred = schemeWasInferred
        self.client = EmbyAPIClient(
            builder: EmbyRequestBuilder(profile: profile),
            session: session
        )
    }

    func currentProfile() -> ServerProfile {
        profile
    }

    /// 只看本地;有效性由第一次鉴权请求验证,启动时不发网络请求。
    func hasStoredToken() async throws -> Bool {
        try await credentials.token(forServer: profile.id) != nil
    }

    /// 有 token,或记住了密码(缺 token 时会静默登录)。false = 需要用户重新登录。
    func canAuthenticateWithoutPrompt() async throws -> Bool {
        if try await hasStoredToken() { return true }
        return try await credentials.password(forServer: profile.id) != nil
    }

    // MARK: - 登录

    /// 探测 → 登录 → 用鉴权请求验证权限(API_CONTRACT.md 1.4)。
    ///
    /// 不碰注册表,持久化由调用方决定:登录失败就不落库。任一步失败都回滚已存的 token。
    ///
    /// - Parameter rememberPassword: true 则存密码供 token 吊销后静默重登;false 则清掉之前存过的密码。
    func login(
        username: String,
        password: String,
        rememberPassword: Bool = false
    ) async throws -> ServerLoginResult {
        let probe = try await probeServer()
        profile.baseURL = probe.baseURL
        profile.apiPathPrefix = probe.compatibility.apiPathPrefix
        await client.updateBaseURL(probe.baseURL)
        await client.updatePathPrefix(probe.compatibility.apiPathPrefix)

        let auth: AuthenticationResult
        do {
            auth = try await client.send(.authenticateByName(username: username, password: password))
        } catch EmbyAPIError.unauthorized {
            throw ServerLoginError.invalidCredentials
        } catch let error as EmbyAPIError {
            throw ServerLoginError.api(error)
        }

        do {
            try await credentials.saveToken(auth.accessToken, forServer: profile.id)
        } catch {
            await clearStoredCredentials()
            throw ServerLoginError.credentialFailure
        }
        await client.setCredentials(accessToken: auth.accessToken, userID: auth.user.id)
        profile.userID = auth.user.id
        // 存用户输入的名字:服务器返回的 Name 可能缺失,不能填假默认值(API_CONTRACT.md 8.1)
        profile.username = username
        profile.serverID = auth.serverID ?? probe.serverID
        profile.serverVersion = probe.compatibility.serverVersion

        do {
            _ = try await verifyAccessWithFreshViews()
        } catch let error as EmbyAPIError {
            await clearStoredCredentials()
            throw ServerLoginError.accessDenied(error)
        }

        do {
            if rememberPassword {
                try await credentials.savePassword(password, forServer: profile.id)
            } else {
                try await credentials.deletePassword(forServer: profile.id)
            }
        } catch {
            await clearStoredCredentials()
            throw ServerLoginError.credentialFailure
        }

        profile.compatibility = probe.compatibility
        // 换用户 / 重新登录后旧缓存是死数据
        await responseCache?.invalidate(serverID: profile.id)
        return ServerLoginResult(profile: profile, compatibility: probe.compatibility)
    }

    /// 先远程吊销(尽力而为),再清本地 token 与记住的密码(否则下次请求会被静默登录回去)。
    func logout() async throws {
        // 远程吊销失败也必须清本地,否则下次启动拿着仍有效的 token 直接进去
        try? await client.sendVoid(.logout)
        try await credentials.deleteToken(forServer: profile.id)
        try await credentials.deletePassword(forServer: profile.id)
        await client.setCredentials(accessToken: nil, userID: nil)
        await responseCache?.invalidate(serverID: profile.id)
    }

    // MARK: - 媒体库入口

    /// 没有 token 时抛 `.unauthorized`。
    func userViews() async throws -> [EmbyView] {
        try await authenticatedViews()
    }

    // MARK: - 浏览

    /// `GET /Users/{UserId}/Items`:列表、分页、搜索共用(API_CONTRACT.md 3.2)。
    func items(_ query: EmbyItemsQuery) async throws -> EmbyItemsResponse<EmbyItem> {
        let userID = try await currentUserID()
        return try await authenticated(.items(userID: userID, query: query))
    }

    /// 单项完整详情;列表接口字段更少,要 Overview 等必须单独取(API_CONTRACT.md 3.2)。
    func item(id: String) async throws -> EmbyItem {
        let userID = try await currentUserID()
        return try await authenticated(.item(userID: userID, itemID: id))
    }

    /// `GET /Users/{UserId}/Items/Resume`:继续观看。
    ///
    /// ⚠️ 必须带 `MediaTypes=Video` + `Recursive=true`,不带时恒返回 0 条(与 Emby Web 写法一致,
    /// `PITFALLS.md` 第 3 节「继续观看」)。
    /// ⛔ 不要改成 `/Items?Filters=IsResumable`:不带 `ParentId` 时在 4.7.11.0 上返回的是媒体库条目。
    /// 可续播与否由服务端判定,客户端不复制 MinResumePct 等规则。
    func resume(limit: Int) async throws -> EmbyItemsResponse<EmbyItem> {
        let userID = try await currentUserID()
        var query = EmbyItemsQuery()
        query.recursive = true
        query.mediaTypes = ["Video"]
        query.limit = limit
        return try await authenticated(.resume(userID: userID, query: query))
    }

    /// 首页 hero 的随机推荐池,走通用 `/Items` 查询(`SortBy=Random`,API_CONTRACT.md 3.2)。
    ///
    /// ⛔ 不用 `/Movies/Recommendations`:只覆盖电影、依赖服务端相似度,实测恒返回 `[]`;
    /// `/Items/{Id}/Similar` 要种子条目,也不适用(`PITFALLS.md` 第 3 节「首页推荐」)。
    /// 只要顶层 Movie / Series、未看过的。
    ///
    /// ⚠️ 结果被响应缓存钉住(key 含完整 query,TTL 内同一批),只在 ⌘R 与播放 Playing / Stopped
    /// 整台作废时换一批。有意为之:每次回首页都换主角首屏会很跳。
    func recommendations(limit: Int) async throws -> [EmbyItem] {
        var query = EmbyItemsQuery()
        query.recursive = true
        query.includeItemTypes = ["Movie", "Series"]
        query.sortBy = ["Random"]
        query.filters = ["IsUnplayed"]
        // Overview / Genres 给 hero 显示;ProviderIds 给弹幕匹配用 Tmdb(`DANMAKU.md` §3)
        query.fields = ["Overview", "Genres", "ProviderIds"]
        query.limit = limit
        return try await items(query).items
    }

    /// `GET /Users/{UserId}/Items/Latest`:最近添加。端点没有 StartIndex / SortBy,不分页。
    func latest(query: EmbyLatestQuery) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        // 返回裸数组 `BaseItemDto[]`,不是 `QueryResult`(API_CONTRACT.md 3.2,PITFALLS.md Q23)
        return try await authenticated(.latest(userID: userID, query: query))
    }

    func seasons(seriesID: String) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.seasons(seriesID: seriesID, userID: userID))
        return response.items
    }

    /// `GET /Shows/NextUp?SeriesId=`(⚠️ 不是 `/Shows/{Id}/NextUp`)。
    /// 服务端排序:看到一半的集在前,其后是下一个未看的集。
    func nextUpEpisode(seriesID: String) async throws -> EmbyItem? {
        let userID = try await currentUserID()
        var query = EmbyNextUpQuery(userID: userID, seriesID: seriesID)
        // 列表接口默认不给 Overview,详情页要显示简介
        query.fields = ["Overview"]
        query.limit = 1
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.nextUp(query: query))
        return response.items.first
    }

    /// 剧集页「该播哪一集」:NextUp → 可续播 → nil(调用方回退到第一集)。
    ///
    /// NextUp 在前是因为 `Filters=IsResumable` 在 4.7.11.0 上表现可疑(Q27 / Q28)。
    /// NextUp 失败就走可续播,第二次失败照常抛出。
    func focusEpisode(seriesID: String) async throws -> EmbyItem? {
        do {
            if let next = try await nextUpEpisode(seriesID: seriesID) { return next }
        } catch {
            // 降级到下一条路,见上
        }
        return try await resumableEpisode(seriesID: seriesID)
    }

    /// 首页 hero「播放」剧集时播哪一集:`focusEpisode` → 第一季第一集 → nil(没有分集)。
    /// 与详情页 `MediaDetailViewModel.loadSeasons` 同一规则(第 0 季排最前时两边都落到它)。
    ///
    /// ⛔ 只在用户点「播放」时调用,不要在渲染 / 轮播时预取:最坏要三个请求。
    func seriesPlaybackEpisode(seriesID: String) async throws -> EmbyItem? {
        if let focus = try await focusEpisode(seriesID: seriesID) { return focus }
        guard let firstSeason = try await seasons(seriesID: seriesID).first else { return nil }
        return try await episodes(seriesID: seriesID, seasonID: firstSeason.id).first
    }

    /// 某部剧里最近播放且可续播的一集(参数见 API_CONTRACT.md 3.2)。可续播由服务端判定。
    /// 没有返回 nil。
    func resumableEpisode(seriesID: String) async throws -> EmbyItem? {
        var query = EmbyItemsQuery()
        query.parentID = seriesID
        query.recursive = true
        query.includeItemTypes = ["Episode"]
        query.filters = ["IsResumable"]
        query.sortBy = ["DatePlayed"]
        query.sortOrder = ["Descending"]
        query.fields = ["Overview"]
        query.limit = 1
        let response = try await items(query)
        return response.items.first
    }

    func episodes(seriesID: String, seasonID: String) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        var query = EmbyEpisodesQuery()
        query.userID = userID
        query.seasonID = seasonID
        // 列表接口默认不给;ProviderIds 给弹幕走 TMDB 降级层(`DANMAKU.md` §3)
        query.fields = ["Overview", "ProviderIds"]
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.episodes(seriesID: seriesID, query: query))
        return response.items
    }

    func similar(itemID: String, limit: Int) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        let query = EmbySimilarQuery(userID: userID, limit: limit)
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.similar(itemID: itemID, query: query))
        return response.items
    }

    /// API_CONTRACT.md 5.5。返回服务端写入后的 `UserData`,调用方用它替换界面状态,不自己推算派生值。
    func setPlayed(itemID: String, played: Bool) async throws -> EmbyUserData {
        let userID = try await currentUserID()
        let userData: EmbyUserData = try await authenticated(.setPlayed(userID: userID, itemID: itemID, played: played))
        // 写操作后缓存不可信,整台作废
        await responseCache?.invalidate(serverID: profile.id)
        return userData
    }

    /// 批量标记(API_CONTRACT.md 5.8)。Emby 没有批量端点,逐条串行发 5.5(⛔ 不并发打服务器),
    /// 全部发完才作废一次缓存。
    ///
    /// 单条失败不中断;返回失败 Id 与第一个错误,调用方必须展示给用户并重读列表。
    ///
    /// - Parameter onProgress: 每成功一条回调(已成功条数, 总数),在 actor 上调用。
    func setPlayed(
        itemIDs: [String],
        played: Bool,
        onProgress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> PlayedBatchResult {
        guard !itemIDs.isEmpty else { return PlayedBatchResult() }
        // 先确认已登录,免得每条都 401 一遍
        let userID = try await currentUserID()
        var result = PlayedBatchResult()
        for (index, itemID) in itemIDs.enumerated() {
            do {
                let userData: EmbyUserData = try await authenticated(
                    .setPlayed(userID: userID, itemID: itemID, played: played)
                )
                result.written[itemID] = userData
                await onProgress(index + 1, itemIDs.count)
            } catch let error as EmbyAPIError {
                // 取消(离开页面)是正常流程,直接抛
                if error == .cancelled { throw error }
                result.failedItemIDs.append(itemID)
                if result.firstError == nil { result.firstError = error }
                if error == .unauthorized {
                    // 401 已处理过,后面只会再 401;没发的也要算失败,否则失败数偏少
                    result.failedItemIDs.append(contentsOf: itemIDs[(index + 1)...])
                    break
                }
            } catch {
                result.failedItemIDs.append(itemID)
                if result.firstError == nil { result.firstError = .transport(.unknown) }
            }
        }
        await responseCache?.invalidate(serverID: profile.id)
        return result
    }

    /// API_CONTRACT.md 5.6。
    func setFavorite(itemID: String, favorite: Bool) async throws -> EmbyUserData {
        let userID = try await currentUserID()
        let userData: EmbyUserData = try await authenticated(.setFavorite(userID: userID, itemID: itemID, favorite: favorite))
        await responseCache?.invalidate(serverID: profile.id)
        return userData
    }

    /// 移出 / 放回继续观看(API_CONTRACT.md 5.7)。播放进度保留、不改 `Played`。
    /// ⚠️ 响应里没有「已隐藏」标记,隐藏态只以是否出现在继续观看里为准,客户端不记账。
    func setHiddenFromResume(itemID: String, hidden: Bool) async throws -> EmbyUserData {
        let userID = try await currentUserID()
        let userData: EmbyUserData = try await authenticated(
            .hideFromResume(userID: userID, itemID: itemID, hide: hidden)
        )
        await responseCache?.invalidate(serverID: profile.id)
        return userData
    }

    /// 图片二进制(API_CONTRACT.md 3.3)。端点是否需要认证未核实(Q12),一律带;
    /// 唯一出口是 `PosterImage`。
    func imageData(itemID: String, type: EmbyImageType, tag: String?, maxWidth: Int) async throws -> Data {
        try await ensureCredentials()
        var query = EmbyImageQuery()
        query.maxWidth = maxWidth
        query.tag = tag
        return try await authenticatedData(.image(itemID: itemID, type: type, query: query))
    }

    // MARK: - 播放

    /// `POST /Items/{Id}/PlaybackInfo`(API_CONTRACT.md 4.3)。
    ///
    /// - Parameter startTimeTicks: 仅转码 seek 用(4.5)。⛔ DirectStream 不要传:它是服务端决策输入,
    ///   可能让本能 DirectStream 的文件改成转码。
    func playbackInfo(itemID: String, startTimeTicks: Int64? = nil) async throws -> EmbyPlaybackInfoResponse {
        let userID = try await currentUserID()
        let request = PlaybackInfoRequest(userID: userID, startTimeTicks: startTimeTicks)
        return try await authenticated(.playbackInfo(itemID: itemID, request: request))
    }

    /// 交给 mpv 的认证头(API_CONTRACT.md 第 6 节):mpv 自己发请求,不走 `URLSession`。
    /// ⛔ 含 token,不得进日志。
    func playbackHeaders() async throws -> [String: String] {
        try await ensureCredentials()
        guard let token = try await credentials.token(forServer: profile.id) else {
            throw EmbyAPIError.unauthorized
        }
        let builder = EmbyRequestBuilder(profile: profile)
        return [
            "Authorization": builder.authorizationHeaderValue(userID: profile.userID),
            "X-Emby-Token": token,
        ]
    }

    // MARK: - 播放上报(API_CONTRACT.md 第 5 节)

    /// `POST /Sessions/Playing*` 统一出口。401 照常处置;调用方 `PlaybackProgressReporter`
    /// 只记录不上抛(5.4),失败不影响播放。
    func reportPlayback(_ endpoint: EmbyEndpoint) async throws {
        try await ensureCredentials()
        try await withUnauthorizedHandling { try await client.sendVoid(endpoint) }
        // Playing / Stopped 改变续播状态,作废缓存;Progress 每 10 秒一次,⛔ 不作废
        // (否则播放期间浏览永远打不到缓存)
        switch endpoint {
        case .sessionsPlaying, .sessionsPlayingStopped:
            await responseCache?.invalidate(serverID: profile.id)
        case .sessionsPlayingProgress, .publicSystemInfo, .systemInfo, .authenticateByName,
             .logout, .userViews, .items, .item, .resume, .latest, .nextUp, .seasons,
             .episodes, .image, .playbackInfo, .similar, .setPlayed, .setFavorite,
             .hideFromResume:
            break
        }
    }

    // MARK: - 探测

    /// 按 API_CONTRACT.md 1.4 的顺序:
    /// 1. `{base}/emby/System/Info/Public` → 前缀 `/emby`
    /// 2. `{base}/System/Info/Public`     → 前缀 ""
    /// 3. 仅当 scheme 是推断的且 host 是本地/私有地址 → 换 http 重试 1、2
    ///
    /// ⛔ 都失败就抛错,不猜其他前缀。
    func probeServer() async throws -> ServerProbeResult {
        var attempts: [(baseURL: URL, prefix: String, fellBack: Bool)] = [
            (profile.baseURL, "/emby", false),
            (profile.baseURL, "", false),
        ]
        if let fallback = httpFallbackURL(from: profile.baseURL) {
            attempts.append((fallback, "/emby", true))
            attempts.append((fallback, "", true))
        }

        for attempt in attempts {
            guard let info = await probeOnce(baseURL: attempt.baseURL, prefix: attempt.prefix) else {
                continue
            }
            await client.updateBaseURL(attempt.baseURL)
            await client.updatePathPrefix(attempt.prefix)
            let compatibility = ServerCompatibility(
                serverName: info.serverName,
                serverVersion: info.version,
                apiPathPrefix: attempt.prefix,
                schemeFellBackToHTTP: attempt.fellBack
            )
            return ServerProbeResult(
                baseURL: attempt.baseURL,
                compatibility: compatibility,
                serverID: info.id
            )
        }
        throw ServerLoginError.unreachable(host: profile.baseURL.host() ?? profile.baseURL.absoluteString)
    }

    // MARK: - 内部实现

    /// 任何失败都视为「这条不通」,探测阶段不区分原因(API_CONTRACT.md 1.4)。
    private func probeOnce(baseURL: URL, prefix: String) async -> EmbyServerInfo? {
        await client.updateBaseURL(baseURL)
        await client.updatePathPrefix(prefix)
        let info: EmbyServerInfo? = try? await client.send(.publicSystemInfo)
        return info
    }

    /// 鉴权请求。可缓存端点先查缓存,fresh 命中零网络;miss 才走网络并落盘原始字节。
    /// epoch 必须在发请求前取:请求在途时发生失效,这次结果不写缓存(见 `EmbyResponseCache`)。
    private func authenticated<T: Decodable & Sendable>(_ endpoint: EmbyEndpoint) async throws -> T {
        guard let cache = responseCache, endpoint.isResponseCacheable else {
            return try await withUnauthorizedHandling { try await client.send(endpoint) }
        }
        let serverID = profile.id
        if let data = await cache.freshData(serverID: serverID, endpoint: endpoint) {
            // 解不动 = 条目损坏:删掉按 miss 走
            if let value = try? await client.decode(T.self, from: data, endpointName: endpoint.name) {
                return value
            }
            await cache.discard(serverID: serverID, endpoint: endpoint)
        }
        let epoch = await cache.currentEpoch(serverID: serverID)
        let (value, data) = try await withUnauthorizedHandling {
            try await client.sendCaching(T.self, endpoint)
        }
        await cache.store(data, serverID: serverID, endpoint: endpoint, epoch: epoch)
        return value
    }

    /// ⛔ 必须实时、不吃缓存:命中缓存会让失效 token 假装登录成功。
    private func verifyAccessWithFreshViews() async throws {
        guard let userID = profile.userID else {
            throw EmbyAPIError.unauthorized
        }
        let _: EmbyItemsResponse<EmbyView> = try await withUnauthorizedHandling {
            try await client.send(.userViews(userID: userID))
        }
    }

    private func authenticatedData(_ endpoint: EmbyEndpoint) async throws -> Data {
        try await withUnauthorizedHandling { try await client.sendData(endpoint) }
    }

    /// 401 的统一处置(API_CONTRACT.md 2.5):
    ///
    /// 1. 那次请求用的 token 已被并发路径换掉 → 用新 token 重发一次;
    /// 2. 记住了密码 → 静默 `AuthenticateByName` 一次,成功后重发一次;
    /// 3. 否则 / 重发仍 401 → 只清这一台的 token(与记住的密码),抛 `.unauthorized` 回登录页。
    ///    不循环重试,不碰其他服务器。
    private func withUnauthorizedHandling<R: Sendable>(
        _ operation: () async throws -> R
    ) async throws -> R {
        let usedToken = await client.currentAccessToken
        do {
            return try await operation()
        } catch EmbyAPIError.unauthorized {
            let tokenWasReplaced = await client.currentAccessToken.map { $0 != usedToken } ?? false
            if !tokenWasReplaced {
                guard try await reauthenticateIfPossible() else {
                    await invalidateSession(ifTokenIs: usedToken)
                    throw EmbyAPIError.unauthorized
                }
            }
        }
        let retriedToken = await client.currentAccessToken
        do {
            return try await operation()
        } catch EmbyAPIError.unauthorized {
            // 新 token 依然被拒,再试也没用
            await invalidateSession(ifTokenIs: retriedToken)
            await forgetPassword()
            throw EmbyAPIError.unauthorized
        }
    }

    /// 没记住密码返回 false。登录本身 401 = 密码已改:清 token 与密码并抛 `.unauthorized`;
    /// 网络等其他错误原样抛、不清任何东西(服务器没表态,不该踢回登录页)。
    private func reauthenticateIfPossible() async throws -> Bool {
        guard let username = profile.username,
              let password = try await credentials.password(forServer: profile.id) else {
            return false
        }
        // 必须在上面的 await 之后检查:期间别的调用可能已经起了一个
        if let running = reauthentication {
            try await running.value
            return true
        }
        let task = Task { try await self.performReauthentication(username: username, password: password) }
        reauthentication = task
        defer { reauthentication = nil }
        try await task.value
        return true
    }

    private func performReauthentication(username: String, password: String) async throws {
        let auth: AuthenticationResult
        do {
            auth = try await client.send(.authenticateByName(username: username, password: password))
        } catch EmbyAPIError.unauthorized {
            await clearStoredCredentials()
            await forgetPassword()
            throw EmbyAPIError.unauthorized
        }
        try await credentials.saveToken(auth.accessToken, forServer: profile.id)
        profile.userID = auth.user.id
        await client.setCredentials(accessToken: auth.accessToken, userID: auth.user.id)
    }

    /// 失败不上抛:不改变「回登录页」的结论,最坏是下次再试一次静默登录。
    private func forgetPassword() async {
        try? await credentials.deletePassword(forServer: profile.id)
    }

    /// 没有 token / 没有 userID 都视为未登录(构造不了 `/Users/{UserId}/...`)。
    private func currentUserID() async throws -> String {
        try await ensureCredentials()
        guard let userID = profile.userID else {
            throw EmbyAPIError.unauthorized
        }
        return userID
    }

    private func authenticatedViews() async throws -> [EmbyView] {
        try await ensureCredentials()
        guard let userID = profile.userID else {
            throw EmbyAPIError.unauthorized
        }
        let response: EmbyItemsResponse<EmbyView> = try await authenticated(.userViews(userID: userID))
        return response.items
    }

    /// 客户端还没 token 时从凭据文件取;没有但记住了密码 → 静默登录;都没有 = 需要登录。
    private func ensureCredentials() async throws {
        if await client.hasToken { return }
        guard let token = try await credentials.token(forServer: profile.id) else {
            guard try await reauthenticateIfPossible() else {
                throw EmbyAPIError.unauthorized
            }
            return
        }
        await client.setCredentials(accessToken: token, userID: profile.userID)
    }

    /// 401 后只清**那次请求用的** token:迟到的旧 token 401 不能把刚登录存好的新 token 删掉。
    private func invalidateSession(ifTokenIs usedToken: String?) async {
        if let current = await client.currentAccessToken, current != usedToken {
            return
        }
        // 读失败按「没有新 token」处理,最坏多一次重新登录
        let stored = try? await credentials.token(forServer: profile.id)
        if let stored, stored != usedToken {
            await client.setCredentials(accessToken: stored, userID: profile.userID)
            return
        }
        // 清理失败不改变「这次是 401」的结论,不上抛
        try? await credentials.deleteToken(forServer: profile.id)
        await client.setCredentials(accessToken: nil, userID: nil)
    }

    /// 登录没成立时回滚,不留孤立凭证。失败不改变「登录失败」的结论。
    private func clearStoredCredentials() async {
        try? await credentials.deleteToken(forServer: profile.id)
        await client.setCredentials(accessToken: nil, userID: nil)
    }

    /// https → http 回退。仅当 scheme 是推断的且 host 是 localhost / .local / 私有网段。
    /// ⛔ 用户明确写了 https 时不得降级(API_CONTRACT.md 1.4)。
    private func httpFallbackURL(from url: URL) -> URL? {
        guard schemeWasInferred,
              let host = url.host(),
              isLocalOrPrivateHost(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https" else {
            return nil
        }
        components.scheme = "http"
        return components.url
    }
}
