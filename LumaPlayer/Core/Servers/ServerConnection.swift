import Foundation

/// 登录流程的失败原因。
///
/// 与 `EmbyAPIError` 分开是刻意的:**登录请求本身的 401 是「用户名或密码错误」,
/// 不是「token 失效」**。若混用,UI 会在输错密码时提示「登录已过期,请重新登录」,
/// 而按 API_CONTRACT.md 2.5 的语义,清 token / 回登录页只适用于**已认证**请求。
enum ServerLoginError: Error, Equatable {
    /// 探测失败:`/emby` 与根两个前缀(加上允许的 http 回退)都拿不到
    /// 可解码的公开信息(API_CONTRACT.md 1.4)
    case unreachable(host: String)
    /// 401:用户名或密码错误。不清 token、不提示「重新登录」
    case invalidCredentials
    /// 登录成功,但用鉴权请求验证访问权限时失败
    case accessDenied(EmbyAPIError)
    /// 探测 / 登录过程中的其他接口错误
    case api(EmbyAPIError)
    /// 本地凭证(凭据文件)写入失败 —— token 没存下
    case credentialFailure
}

/// 探测结果。http 回退成功时 `baseURL` 的 scheme 会变成 http
/// (API_CONTRACT.md 1.4)。
struct ServerProbeResult: Sendable, Equatable {
    let baseURL: URL
    let compatibility: ServerCompatibility
    /// 公开信息端点报出的服务器 Id;端点没给就是 nil(不填假值)
    let serverID: String?
}

/// 一次成功登录的产物。
struct ServerLoginResult: Sendable, Equatable {
    /// 已回填 serverID / serverVersion / userID / username / apiPathPrefix 的档案
    let profile: ServerProfile
    let compatibility: ServerCompatibility
}

/// 单台服务器的连接、探测与登录(actor:持有可变档案与客户端状态,
/// CLAUDE.md「并发分层」的 `Core/Servers` 分层)。
///
/// 一台服务器一个实例、一个 `EmbyAPIClient`:token 不共享,
/// 因此「一台 401 不影响另一台」是结构上成立的,不是靠调用顺序保证的。
actor ServerConnection {
    private var profile: ServerProfile
    private let credentials: CredentialStore
    private let client: EmbyAPIClient
    /// 接口响应缓存。nil = 不缓存(单测默认),
    /// 生产路径由 `AppContainer` 注入共享实例。
    private let responseCache: EmbyResponseCache?
    /// 地址里的 scheme 是不是规范化算法补的(API_CONTRACT.md 1.3)。
    /// 只有为 true 时才允许局域网 http 回退(1.4)。
    private let schemeWasInferred: Bool
    /// 在途的静默重新登录。并发的多个 401 / 缺 token 共用同一次登录,
    /// 不各自打一遍 `AuthenticateByName`。
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

    /// 本地有没有这台服务器的 token。有效性由第一次鉴权请求验证,启动时不发网络请求。
    func hasStoredToken() async throws -> Bool {
        try await credentials.token(forServer: profile.id) != nil
    }

    /// 免输入就能进:有 token,或记住了密码(缺 token 时第一次鉴权请求前会静默登录)。
    /// false = 需要用户重新登录。
    func canAuthenticateWithoutPrompt() async throws -> Bool {
        if try await hasStoredToken() { return true }
        return try await credentials.password(forServer: profile.id) != nil
    }

    // MARK: - 登录

    /// 探测(`/emby` 前缀 + 允许的 http 回退)→ 登录 → 用鉴权请求验证权限
    /// (API_CONTRACT.md 1.4 的顺序)。
    ///
    /// 返回更新后的档案与兼容信息;**本方法不碰注册表**,持久化由调用方决定,
    /// 这样「登录失败就不落库」(不留一条存在但用不了的服务器)。
    ///
    /// - Parameter rememberPassword: true 则验证通过后把密码存凭据文件,供 token 被吊销后
    ///   静默重登;false 则顺手清掉这台之前可能存过的密码(取消勾选 = 忘记)。
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
        // 存用户输入的名字,不是服务器返回的 Name —— 后者可能缺失,
        // 而填假默认值是被禁止的(API_CONTRACT.md 8.1)
        profile.username = username
        profile.serverID = auth.serverID ?? probe.serverID
        profile.serverVersion = probe.compatibility.serverVersion

        do {
            _ = try await verifyAccessWithFreshViews()
        } catch let error as EmbyAPIError {
            // 验证失败 = 这次登录没成立:顺手清掉刚存的 token,
            // 否则会留下「没有对应服务器档案」的孤立凭证。
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
        // 换用户 / 重新登录后旧用户的缓存条目就是死数据,整台作废
        await responseCache?.invalidate(serverID: profile.id)
        return ServerLoginResult(profile: profile, compatibility: probe.compatibility)
    }

    /// 登出:先远程吊销(尽力而为),再清本地 token 与记住的密码
    /// (否则下一次请求会被静默登录回去)。
    func logout() async throws {
        // 远程吊销失败也要清本地 token —— 否则用户以为已登出,下次启动
        // 却拿着一个仍有效的 token 直接进去了。这里不是「静默吞错」:
        // 失败不影响本地登出的语义,也不需要用户做任何补救。
        try? await client.sendVoid(.logout)
        try await credentials.deleteToken(forServer: profile.id)
        try await credentials.deletePassword(forServer: profile.id)
        await client.setCredentials(accessToken: nil, userID: nil)
        // 已登出服务器的媒体数据不该继续留在本地缓存里
        await responseCache?.invalidate(serverID: profile.id)
    }

    // MARK: - 媒体库入口

    /// `GET /Users/{UserId}/Views`。没有 token 时抛 `.unauthorized`(需要登录)。
    func userViews() async throws -> [EmbyView] {
        try await authenticatedViews()
    }

    // MARK: - 浏览

    /// `GET /Users/{UserId}/Items` —— 列表、分页、搜索共用(API_CONTRACT.md 3.2)。
    ///
    /// 返回的 `totalRecordCount` 是服务端总数,UI 据此判断还有没有下一页。
    func items(_ query: EmbyItemsQuery) async throws -> EmbyItemsResponse<EmbyItem> {
        let userID = try await currentUserID()
        return try await authenticated(.items(userID: userID, query: query))
    }

    /// `GET /Users/{UserId}/Items/{Id}` —— 单项完整详情(列表接口字段更少,
    /// 需要 Overview 等字段时必须单独取,API_CONTRACT.md 3.2)。
    func item(id: String) async throws -> EmbyItem {
        let userID = try await currentUserID()
        return try await authenticated(.item(userID: userID, itemID: id))
    }

    /// `GET /Users/{UserId}/Items/Resume` —— 继续观看(看了一半的内容)。
    ///
    /// ⚠️ **必须带 `MediaTypes=Video` + `Recursive=true`**:本地 Emby 4.9.5.0 实测,
    /// 不带任何参数时该端点**恒返回 0 条**(库里明明有可续播内容)。这是 Emby Web
    /// 自己查「继续观看」的写法 —— 官方客户端抓包为
    /// `/Items/Resume?Recursive=true&MediaTypes=Video&Limit=...`;`MediaTypes`
    /// 在官方 OpenAPI 4.1.1.0 上 ✅(2026-09-23 核实)。实测与选型见
    /// `PITFALLS.md 第 3 节「继续观看」`。
    ///
    /// ⛔ **不要**改成 `/Items?Filters=IsResumable`:那是不带 `ParentId` 的查询,
    /// 在用户那台 4.7.11.0 上实测返回的是顶层「媒体库」条目,不是影片。
    /// 「算不算可续播」一律由服务端判定,客户端不复制 MinResumePct 等规则。
    func resume(limit: Int) async throws -> EmbyItemsResponse<EmbyItem> {
        let userID = try await currentUserID()
        var query = EmbyItemsQuery()
        query.recursive = true
        query.mediaTypes = ["Video"]
        query.limit = limit
        return try await authenticated(.resume(userID: userID, query: query))
    }

    /// `GET /Users/{UserId}/Items` —— 首页顶部的**随机推荐池**(API_CONTRACT.md 3.2)。
    ///
    /// ⛔ **不是** Emby 的 `/Movies/Recommendations`。那个端点官方参考里确实有
    /// (`dev.emby.media` MoviesService),但它的语义是「因为你看了 X」:拿最近几部
    /// 已看电影算相似片。三条硬伤 —— 只覆盖电影不带剧集、依赖服务端 `Genres` /
    /// `ProviderIds` 算相似度、**本机 4.9.5.0 实测把电影标成已看后仍恒返回 `[]`**
    /// (2026-10-15,见 `PITFALLS.md` 第 3 节「首页推荐」)。`/Items/{Id}/Similar`
    /// 同理不可用:它需要**一个种子条目**,当首页的推荐源无从下手。
    ///
    /// 所以走已登记的通用查询,零新增端点、零新增参数名:
    /// `SortBy=Random` 本来就写在 API_CONTRACT.md 3.2 的 `SortBy` 白名单里,
    /// 实测每次给不同的一批。`Filters=IsUnplayed` 不把已看的推上来;
    /// `IncludeItemTypes` 只要**顶层**的 Movie / Series —— 推一集太碎。
    /// `Fields=Overview,Genres`:hero 显示两行简介和前两个类型,列表接口默认不给这两个
    /// (3.2;两个字段名都在 3.2 的 `Fields` 白名单里)。
    ///
    /// ⚠️ **会被响应缓存钉住**:`.items` 在 `EmbyResponseCache` 的白名单里,
    /// 而缓存 key 含完整 query,所以同一个 TTL(1 小时)窗口内这一批是**稳定**的;
    /// 换一批只发生在手动刷新(⌘R)与播放上报 Playing / Stopped —— 那三处都会
    /// 整台作废(见 `EmbyResponseCache` 的失效规则表)。这是有意为之,不是漏了:
    /// 每次回首页都换主角会让首屏很跳。登记在 `PITFALLS.md`。
    func recommendations(limit: Int) async throws -> [EmbyItem] {
        var query = EmbyItemsQuery()
        query.recursive = true
        query.includeItemTypes = ["Movie", "Series"]
        query.sortBy = ["Random"]
        query.filters = ["IsUnplayed"]
        // ProviderIds:从首页直接点播时弹幕匹配要它的 Tmdb(`DANMAKU.md` §3)
        query.fields = ["Overview", "Genres", "ProviderIds"]
        query.limit = limit
        return try await items(query).items
    }

    /// `GET /Users/{UserId}/Items/Latest` —— 最近添加(API_CONTRACT.md 3.2)。
    ///
    /// 该端点没有 StartIndex / SortBy(官方 OpenAPI 核实),所以这里不给分页。
    func latest(query: EmbyLatestQuery) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        // 与其他列表端点不同,Latest 返回裸数组 `BaseItemDto[]`,不是
        // `QueryResult<BaseItemDto>`(官方 OpenAPI 4.1.1.0 核实,API_CONTRACT.md 3.2)。
        // 按 `{"Items": ...}` 解会整段失败(docs/PITFALLS.md Q23)。
        return try await authenticated(.latest(userID: userID, query: query))
    }

    /// `GET /Shows/{Id}/Seasons` —— 剧集的季列表(API_CONTRACT.md 3.2)。
    func seasons(seriesID: String) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.seasons(seriesID: seriesID, userID: userID))
        return response.items
    }

    /// `GET /Shows/NextUp` —— 某部剧「接着看哪一集」(官方 OpenAPI 4.1.1.0 核实 2026-09-23)。
    ///
    /// ⚠️ 路径是 `/Shows/NextUp`,`SeriesId` 走查询参数 —— **不是** `/Shows/{Id}/NextUp`。
    /// 语义由服务端算:看到一半的集排最前,其后是下一个未看的集(本地 4.9.5.0 实测:
    /// 4 条里首条正是进度 73091590 的 S01E02)。
    func nextUpEpisode(seriesID: String) async throws -> EmbyItem? {
        let userID = try await currentUserID()
        var query = EmbyNextUpQuery(userID: userID, seriesID: seriesID)
        // 列表接口默认不给 Overview(3.2),定位到集后要在详情页显示简介,显式要一次
        query.fields = ["Overview"]
        query.limit = 1
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.nextUp(query: query))
        return response.items.first
    }

    /// 剧集页「该播哪一集」:NextUp → 可续播 → nil(由调用方回退到第一集)。
    ///
    /// **NextUp 排在前面**,不是因为它更「新」,而是因为它不依赖
    /// `Filters=IsResumable` —— 那个 filter 在用户那台 4.7.11.0 上的表现可疑
    /// (不带 `ParentId` 时返回的是媒体库条目,见 Q27 / Q28)。NextUp 不可用时
    /// 退回可续播那套,第二次查询失败照常抛出,由调用方降级到第一集。
    func focusEpisode(seriesID: String) async throws -> EmbyItem? {
        do {
            if let next = try await nextUpEpisode(seriesID: seriesID) { return next }
        } catch {
            // 上面已注明:NextUp 拿不到就走下一条路,不是把错误吞掉。
        }
        return try await resumableEpisode(seriesID: seriesID)
    }

    /// 剧集「直接播放」该播哪一集(首页 hero 的播放按钮用):
    /// `focusEpisode`(NextUp → 可续播)→ 第一季的第一集 → nil(这部剧没有分集)。
    ///
    /// 与详情页定位初始集**同一套规则**(`MediaDetailViewModel` 的 `loadSeasons`):
    /// 看过就接着看,没看过就从头。「第一季」取 `/Shows/{Id}/Seasons` 的第一项,
    /// 与详情页一致 —— 服务器把「特别篇」(第 0 季)排在最前时,两边都会落到它。
    ///
    /// 只在用户点「播放」时调用,⛔ 不要在 hero 渲染 / 轮播切换时预先调用:
    /// 最坏要三个请求(NextUp、可续播、季 + 分集),每张轮播都发一遍是在白白打服务器。
    func seriesPlaybackEpisode(seriesID: String) async throws -> EmbyItem? {
        if let focus = try await focusEpisode(seriesID: seriesID) { return focus }
        guard let firstSeason = try await seasons(seriesID: seriesID).first else { return nil }
        return try await episodes(seriesID: seriesID, seasonID: firstSeason.id).first
    }

    /// `GET /Users/{UserId}/Items` —— 某部剧里**最近播放且可续播**的那一集。
    ///
    /// 定位剧集页的初始集用(API_CONTRACT.md 3.2 的参数表):
    /// `ParentId` + `Recursive` + `IncludeItemTypes=Episode` +
    /// `Filters=IsResumable` + `SortBy=DatePlayed` + `SortOrder=Descending` + `Limit=1`。
    ///
    /// 「算不算可续播」由服务端判定(MinResumePct / MaxResumePct / 最短可续播时长等
    /// 规则),客户端不复制这套规则 —— 与 `MediaDetailViewModel.refreshDetail`
    /// 的立场一致:续播位置与已看状态一律以服务端为准。
    ///
    /// 没有可续播的集时返回 nil,由调用方回退到第一集。
    func resumableEpisode(seriesID: String) async throws -> EmbyItem? {
        var query = EmbyItemsQuery()
        query.parentID = seriesID
        query.recursive = true
        query.includeItemTypes = ["Episode"]
        query.filters = ["IsResumable"]
        query.sortBy = ["DatePlayed"]
        query.sortOrder = ["Descending"]
        // 列表接口默认不给 Overview(3.2),定位到集后要在详情页显示简介,显式要一次
        query.fields = ["Overview"]
        query.limit = 1
        let response = try await items(query)
        return response.items.first
    }

    /// `GET /Shows/{Id}/Episodes` —— 某一季的分集(API_CONTRACT.md 3.2)。
    func episodes(seriesID: String, seasonID: String) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        var query = EmbyEpisodesQuery()
        query.userID = userID
        query.seasonID = seasonID
        // 列表接口默认不给 Overview(3.2);分集行要显示简介,显式要一次。
        // ProviderIds 同理:弹幕匹配要靠它的 Tmdb 走 TMDB 降级层(`DANMAKU.md` §3)。
        query.fields = ["Overview", "ProviderIds"]
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.episodes(seriesID: seriesID, query: query))
        return response.items
    }

    /// `GET /Items/{Id}/Similar` —— 相似推荐(API_CONTRACT.md 3.2)。
    func similar(itemID: String, limit: Int) async throws -> [EmbyItem] {
        let userID = try await currentUserID()
        let query = EmbySimilarQuery(userID: userID, limit: limit)
        let response: EmbyItemsResponse<EmbyItem> = try await authenticated(.similar(itemID: itemID, query: query))
        return response.items
    }

    /// 标记已看 / 未看(API_CONTRACT.md 5.5)。返回服务端写入后的 `UserData`,
    /// 调用方用它替换界面上的状态 —— 不自己推算 `PlayCount` 之类的派生值。
    func setPlayed(itemID: String, played: Bool) async throws -> EmbyUserData {
        let userID = try await currentUserID()
        let userData: EmbyUserData = try await authenticated(.setPlayed(userID: userID, itemID: itemID, played: played))
        // 写操作改变了列表里的 UserData:缓存的响应已经不可信,整台作废
        await responseCache?.invalidate(serverID: profile.id)
        return userData
    }

    /// 批量标记已看 / 未看(API_CONTRACT.md 5.8)。
    ///
    /// Emby **没有批量端点**(官方 OpenAPI 4.1.1.0 只有 `POST|DELETE /Users/{UserId}/PlayedItems/{Id}`),
    /// 所以这里就是**逐条**发 5.5 的请求:串行、不并发(CLAUDE.md「真实服务器使用纪律」:
    /// 不对同一台服务器并发轰炸),全部发完才让缓存作废一次。
    ///
    /// 失败**不中断**:网络抖一下就丢掉后面几十集比「有几集没标上」更糟。
    /// 返回实际失败的条目 Id 与第一个错误 —— 调用方必须把它们摆到用户面前
    /// (CLAUDE.md 硬规则 4:不静默吞错),并据此重读列表,让界面与服务端一致。
    ///
    /// - Parameter onProgress: 每成功一条回调一次(已成功条数, 总数)。在 actor 上调用,
    ///   调用方自行切回主线程。
    func setPlayed(
        itemIDs: [String],
        played: Bool,
        onProgress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> PlayedBatchResult {
        guard !itemIDs.isEmpty else { return PlayedBatchResult() }
        // 先确保已登录:一条都没发就 401 的话,没必要把每条都失败一遍
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
                // 取消是正常流程(离开页面),不当成失败继续往下发
                if error == .cancelled { throw error }
                result.failedItemIDs.append(itemID)
                if result.firstError == nil { result.firstError = error }
                if error == .unauthorized {
                    // 401 已经由 withUnauthorizedHandling 处理过(重登或清 token):
                    // 后面的请求只会再 401 一遍,没有继续的意义。但**没发出去的也要算失败**
                    // —— 否则调用方拿到的失败数比实际少,会以为剩下的标上了(硬规则 4)
                    result.failedItemIDs.append(contentsOf: itemIDs[(index + 1)...])
                    break
                }
            } catch {
                result.failedItemIDs.append(itemID)
                if result.firstError == nil { result.firstError = .transport(.unknown) }
            }
        }
        // 一次写操作改了多条 UserData:整台作废(与单条 setPlayed 同一条规则)
        await responseCache?.invalidate(serverID: profile.id)
        return result
    }

    /// 收藏 / 取消收藏(API_CONTRACT.md 5.6)。返回写入后的 `UserData`。
    func setFavorite(itemID: String, favorite: Bool) async throws -> EmbyUserData {
        let userID = try await currentUserID()
        let userData: EmbyUserData = try await authenticated(.setFavorite(userID: userID, itemID: itemID, favorite: favorite))
        await responseCache?.invalidate(serverID: profile.id)
        return userData
    }

    /// 移出 / 放回继续观看(API_CONTRACT.md 5.7)。返回写入后的 `UserData`。
    ///
    /// 与「标记已看」的区别:只让条目不在 `/Items/Resume` 里出现,**播放进度原样保留**
    /// (本地 4.9.5.0 实测),也不会把 `Played` 改成 true —— 适合「看了一点、暂时不想看」。
    /// ⚠️ 响应里没有「已隐藏」标记,隐藏态只以「是否出现在继续观看里」为准,
    /// 客户端不自己记账。
    func setHiddenFromResume(itemID: String, hidden: Bool) async throws -> EmbyUserData {
        let userID = try await currentUserID()
        let userData: EmbyUserData = try await authenticated(
            .hideFromResume(userID: userID, itemID: itemID, hide: hidden)
        )
        await responseCache?.invalidate(serverID: profile.id)
        return userData
    }

    /// `GET /Items/{Id}/Images/{Type}` —— 图片二进制(API_CONTRACT.md 3.3)。
    ///
    /// ⛔ 图片同样走鉴权请求:端点是否需要认证头尚未核实(docs/KNOWN_ISSUES.md Q12),
    /// 因此一律带上;图片请求的唯一出口是 `Components/PosterImage.swift`。
    func imageData(itemID: String, type: EmbyImageType, tag: String?, maxWidth: Int) async throws -> Data {
        try await ensureCredentials()
        var query = EmbyImageQuery()
        query.maxWidth = maxWidth
        query.tag = tag
        return try await authenticatedData(.image(itemID: itemID, type: type, query: query))
    }

    // MARK: - 播放

    /// `POST /Items/{Id}/PlaybackInfo` —— 播放信息(API_CONTRACT.md 4.3)。
    ///
    /// 不发 `EnableDirectPlay`、带最小 `DeviceProfile`(API_CONTRACT.md 4.3,issue #2)。
    ///
    /// - Parameter startTimeTicks: 仅转码 seek 使用(4.5 的 `StartTimeTicks`)。
    ///   DirectStream 路径**不要传**:它是服务端的决策输入之一,贸然传值
    ///   可能让本来能 DirectStream 的文件改成转码。
    func playbackInfo(itemID: String, startTimeTicks: Int64? = nil) async throws -> EmbyPlaybackInfoResponse {
        let userID = try await currentUserID()
        let request = PlaybackInfoRequest(userID: userID, startTimeTicks: startTimeTicks)
        return try await authenticated(.playbackInfo(itemID: itemID, request: request))
    }

    /// 交给 mpv 的认证头(API_CONTRACT.md 第 6 节)。
    ///
    /// 播放是 mpv 自己发的 HTTP 请求,不走 `URLSession`,所以认证信息必须
    /// **显式取出**再交给它;漏了就是 401,而且从 mpv 侧很难定位。
    /// ⛔ 返回值含 token,不得进日志 —— 打印前先过 `SecretRedactor`。
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

    /// `POST /Sessions/Playing*` 三端点的统一出口。
    ///
    /// 401 处置与其他鉴权请求一致(2.5:清本台 token);但**失败不得影响播放**
    /// —— 调用方是 `PlaybackProgressReporter`,它只记录失败不往上抛(5.4),
    /// 所以这里抛出的错误永远不会到达 UI。
    func reportPlayback(_ endpoint: EmbyEndpoint) async throws {
        try await ensureCredentials()
        try await withUnauthorizedHandling { try await client.sendVoid(endpoint) }
        // Playing / Stopped 意味着播放位置与续播列表变了(resume / nextUp /
        // 详情里的 UserData),缓存的响应不再可信。**Progress tick 不失效**:
        // 它每 10 秒一次,会让播放期间的浏览永远打不到缓存
        // (`EmbyResponseCache` 的失效规则表)。
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

    /// 按 API_CONTRACT.md 1.4 的顺序探测:
    /// 1. `{base}/emby/System/Info/Public` → 前缀 `/emby`
    /// 2. `{base}/System/Info/Public`     → 前缀 ""
    /// 3. 仅当 scheme 是推断的且 host 是本地/私有地址 → 换 http 重试 1、2
    ///
    /// ⛔ 都失败就抛错,不继续猜其他 path 前缀(1.4)。
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

    /// 探测一次。**任何**失败(网络 / 非 2xx / 解不出 JSON)都视为「这条不通」:
    /// 探测阶段无法也不需要区分失败原因(API_CONTRACT.md 1.4)。
    private func probeOnce(baseURL: URL, prefix: String) async -> EmbyServerInfo? {
        await client.updateBaseURL(baseURL)
        await client.updatePathPrefix(prefix)
        let info: EmbyServerInfo? = try? await client.send(.publicSystemInfo)
        return info
    }

    /// 鉴权请求:401 时按 API_CONTRACT.md 2.5 处理(见 `withUnauthorizedHandling`)。
    ///
    /// 可缓存端点(`EmbyEndpoint.isResponseCacheable`)先查本地缓存:
    /// fresh 命中直接解码返回、零网络(TTL 内不请求服务器);
    /// miss / 过期才走网络,成功后把**原始响应字节**落盘。epoch 必须在
    /// **发请求前**取 —— 失效发生在请求在途时,这次结果作废不写缓存
    /// (`EmbyResponseCache` 的竞态防护)。
    private func authenticated<T: Decodable & Sendable>(_ endpoint: EmbyEndpoint) async throws -> T {
        guard let cache = responseCache, endpoint.isResponseCacheable else {
            return try await withUnauthorizedHandling { try await client.send(endpoint) }
        }
        let serverID = profile.id
        if let data = await cache.freshData(serverID: serverID, endpoint: endpoint) {
            // 解不动 = 缓存条目损坏:删掉按 miss 走网络,不让坏数据挡路
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

    /// 登录后的访问权限验证:**必须实时**,不吃缓存 ——
    /// 命中缓存会让一个失效 token 假装登录成功(见 `login` 调用处)。
    private func verifyAccessWithFreshViews() async throws {
        guard let userID = profile.userID else {
            throw EmbyAPIError.unauthorized
        }
        let _: EmbyItemsResponse<EmbyView> = try await withUnauthorizedHandling {
            try await client.send(.userViews(userID: userID))
        }
    }

    /// 二进制响应(图片)的鉴权请求:不经过 JSON 解码,但 401 处置与上面一致。
    private func authenticatedData(_ endpoint: EmbyEndpoint) async throws -> Data {
        try await withUnauthorizedHandling { try await client.sendData(endpoint) }
    }

    /// 401 的统一处置(API_CONTRACT.md 2.5):
    ///
    /// 1. 那次请求用的 token 已被换掉(并发的另一条路径刚登录过)→ 用新 token
    ///    把原请求**重发一次**;
    /// 2. 用户记住了密码 → 静默 `AuthenticateByName` **一次**,成功后原请求**重发一次**;
    /// 3. 否则 / 重发仍 401 → 只清**这一台**的 token(记住的密码也清,免得下次又
    ///    用一个无效组合登录),抛 `.unauthorized` 让 UI 回登录页。
    ///    不会循环重试,不碰其他服务器。
    ///
    /// 没记住密码时没有静默重登(`API_CONTRACT.md 2.5`)。
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
            // 换过的新 token(别处登录的或刚静默登录拿到的)依然被拒:
            // 不是 token 新旧的问题,再试也没用
            await invalidateSession(ifTokenIs: retriedToken)
            await forgetPassword()
            throw EmbyAPIError.unauthorized
        }
    }

    /// 用记住的密码静默重新登录。没记住密码返回 false(调用方走原来的 401 处置)。
    ///
    /// 登录请求本身 401 = 密码已在服务端改过:清 token 与密码,抛 `.unauthorized`。
    /// 网络等其他错误原样往上抛、不清任何东西 —— 此时服务器没有表态,
    /// 不该把用户踢到登录页,下次请求再试。
    private func reauthenticateIfPossible() async throws -> Bool {
        guard let username = profile.username,
              let password = try await credentials.password(forServer: profile.id) else {
            return false
        }
        // 上面的 await 之后才检查在途任务,中间别的调用可能已经起了一个
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
        // 同一用户名在同一台服务器上 UserId 不变;以返回值为准,免得路径里的 UserId 过时
        profile.userID = auth.user.id
        await client.setCredentials(accessToken: auth.accessToken, userID: auth.user.id)
    }

    /// 清掉记住的密码。失败不改变调用处「回登录页」的结论,故不往上抛
    /// (最坏结果是下次又试一次静默登录再失败)。
    private func forgetPassword() async {
        try? await credentials.deletePassword(forServer: profile.id)
    }

    /// 当前用户 Id。没有 token / 没有 userID 都视为未登录 ——
    /// 这两者都无法构造 `/Users/{UserId}/...` 路径。
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
            // 没有 userId 就没法构造 /Users/{UserId}/Views —— 视为未登录
            throw EmbyAPIError.unauthorized
        }
        let response: EmbyItemsResponse<EmbyView> = try await authenticated(.userViews(userID: userID))
        return response.items
    }

    /// 首次鉴权请求前从本地凭据取回 token(启动恢复会话用)。
    /// 本地没有 token = 需要登录。
    /// 本地没有 token 但记住了密码 → 静默登录;两者都没有 = 需要登录。
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

    /// 401 后清掉这台的 token —— 但**只清那次请求用的那个**。
    ///
    /// 并发请求里,旧 token 的 401 可能在新 token 已经存好之后才回来
    /// (用户刚在登录面板登录过)。不做这个比对,
    /// 迟到的 401 会把新 token 删掉,用户刚登录完又被踢回登录页。
    private func invalidateSession(ifTokenIs usedToken: String?) async {
        if let current = await client.currentAccessToken, current != usedToken {
            return
        }
        // 读失败按「没有新 token」处理:最坏结果是多一次重新登录,与旧行为相同
        let stored = try? await credentials.token(forServer: profile.id)
        if let stored, stored != usedToken {
            await client.setCredentials(accessToken: stored, userID: profile.userID)
            return
        }
        // 清理失败不改变「这次请求是 401」的结论:上层拿到的仍是
        // `.unauthorized`,用户看到的是重新登录。故不把凭据文件错误往上抛。
        try? await credentials.deleteToken(forServer: profile.id)
        await client.setCredentials(accessToken: nil, userID: nil)
    }

    /// 这次登录没成立时回滚:清掉刚存的 token(不留孤立凭证)。
    private func clearStoredCredentials() async {
        // 同上:回滚失败不改变「登录失败」的结论
        try? await credentials.deleteToken(forServer: profile.id)
        await client.setCredentials(accessToken: nil, userID: nil)
    }

    /// https → http 的回退 URL。**仅当**两条同时成立才返回非 nil:
    /// 1. scheme 是规范化算法补的(用户没写 `https://`);
    /// 2. host 是 localhost / .local / 私有网段。
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
