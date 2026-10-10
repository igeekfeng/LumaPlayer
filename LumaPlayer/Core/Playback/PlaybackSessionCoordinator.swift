import Foundation

/// 会话准备的注入点。
///
/// 生产实现就是 `PlaybackSessionCoordinator`。抽成协议的理由与 `PlaybackEngine`
/// 相同:**接线规则**(什么时候 seek、什么时候上报、起播偏好什么时候套上去、转码 seek
/// 怎么重新起流)不该依赖网络,而本机起不了 App(`KNOWN_ISSUES.md` Q34)——
/// 接线测试只能靠替身把会话喂进去。会话准备自身(过 FFI 边界那一段)由
/// `RustPlaybackDecisionTests` 与 `Scripts/verify-avkit-decision.sh` 覆盖。
protocol PlaybackSessionPreparing: Sendable {
    /// - Parameter startTimeTicks: 转码起流位置(4.5);`nil` = 从头取一次会话
    func makeSession(startTimeTicks: Int64?) async throws -> PlaybackSession
}

/// 一次播放会话的编排:取 `PlaybackInfo` → **Rust 决策** → 拼地址 + 挂认证头
/// (`ARCHITECTURE.md` 6.5)。
///
/// ## `exp/avkit-rust-core` 上它变了什么
///
/// `main` 上这里调的是 Swift 的 `PlaybackDecisionEngine`;本分支决策搬去了 Rust,
/// 所以本 actor 的职责收窄成两件**只有 Swift 做得了**的事:
///
/// 1. 把响应**原样**交给 Rust(`decidePlayback(playbackInfoJson:)`)——
///    决策要看的字段比 Swift 的 DTO 多,先解码再重编码会把它丢掉;
/// 2. 拼 URL 与挂认证头 —— 站点根 / `/emby` 前缀与 token 都在 Swift 侧
///    (`PlaybackURLBuilder` + `ServerConnection.playbackHeaders()`);
///    ③ 从响应里取出**决策选中的那条** `MediaSource`(核轨要用它的 `MediaStreams`)。
///
/// 放在 actor 里是因为它串行地读连接状态(档案的 baseURL / 前缀与本地 token),
/// 这些状态本来就属于 `ServerConnection`;本 actor 自己**不缓存任何凭据**,每次都现取。
actor PlaybackSessionCoordinator: PlaybackSessionPreparing {
    private let connection: ServerConnection
    private let itemID: String

    init(connection: ServerConnection, itemID: String) {
        self.connection = connection
        self.itemID = itemID
    }

    /// 产出一份可直接交给播放内核的会话。
    ///
    /// 失败来源有三种:
    /// - `EmbyAPIError`(接口层,含 401 —— 由 `ServerConnection` 按 API_CONTRACT.md 2.5
    ///   清掉本台 token);
    /// - `PlaybackFailureFfi`(Rust 决策:服务端拒绝 / 没有可播路径 / 给了放不了的直连流);
    /// - `PlaybackError`(本地拼 URL 失败、FFI 取值漂移、找不到被选中的源)。
    ///
    /// - Parameter startTimeTicks: 转码起流位置(4.5)。**只在确知走转码之后**才传:
    ///   它是服务端的决策输入之一,对 DirectStream 无意义。调用方因此先取一次会话,
    ///   确认为转码后再带本参数重取(与 `main` 同一手法)。
    func makeSession(startTimeTicks: Int64? = nil) async throws -> PlaybackSession {
        let data = try await connection.playbackInfoJSON(
            itemID: itemID,
            startTimeTicks: startTimeTicks
        )

        // ⛔ 判定的唯一入口:原始 JSON 直接过 FFI,Swift 不先解一遍
        let decision = try decidePlayback(playbackInfoJson: String(decoding: data, as: UTF8.self))

        let profile = await connection.currentProfile()
        let headers = try await connection.playbackHeaders()
        let plan = try PlaybackPlanBuilder.plan(
            from: decision,
            urlBuilder: PlaybackURLBuilder(
                baseURL: profile.baseURL,
                apiPathPrefix: profile.apiPathPrefix
            ),
            headers: headers
        )

        let response = try JSONDecoder().decode(EmbyPlaybackInfoResponse.self, from: data)
        // 决策说播哪条源,核轨就得拿那条源的 MediaStreams —— 取错源会变成
        // 「播的是 A、判的是 B」,静默删轨的守卫会因此失效。
        guard let source = response.mediaSources?.first(where: { $0.id == decision.mediaSourceId }) else {
            throw PlaybackError.mediaSourceNotFound(id: decision.mediaSourceId)
        }

        return PlaybackSession(plan: plan, mediaSource: source, decision: decision)
    }
}
