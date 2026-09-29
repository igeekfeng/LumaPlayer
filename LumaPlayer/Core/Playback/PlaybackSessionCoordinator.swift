import Foundation

/// 一次播放会话的编排:取 PlaybackInfo → 决策 → 补认证头
/// (ARCHITECTURE.md 6.5)。
///
/// 放在 actor 里是因为它串行地读连接状态(档案的 baseURL / `/emby` 前缀
/// 与本地 token),这些状态本来就属于 `ServerConnection`;
/// 协调器自己**不缓存任何凭据**,每次都现取。
///
/// ⛔ 决策本身不在这里 —— 那是 `PlaybackDecisionEngine` 的纯函数,
/// 这样「仅转码可用」这类分支可以脱离网络单测。
actor PlaybackSessionCoordinator {
    private let connection: ServerConnection
    private let itemID: String

    init(connection: ServerConnection, itemID: String) {
        self.connection = connection
        self.itemID = itemID
    }

    /// 产出可直接交给 mpv 的播放会话。
    ///
    /// 失败来源有两种:`EmbyAPIError`(接口层,含 401 —— 由
    /// `ServerConnection` 按 API_CONTRACT.md 2.5 清掉本台 token)与
    /// `PlaybackError`(服务端给了响应但没有可播路径)。
    ///
    /// - Parameter startTimeTicks: 转码起流位置(4.5)。**只在确知走转码
    ///   之后**才传:它是服务端的决策输入之一,对 DirectStream 无意义。
    ///   `PlayerViewModel` 因此先取一次会话,确认为转码后再带本参数重取。
    func makeSession(startTimeTicks: Int64? = nil) async throws -> PlaybackSession {
        let response = try await connection.playbackInfo(
            itemID: itemID,
            startTimeTicks: startTimeTicks
        )
        let profile = await connection.currentProfile()
        let headers = try await connection.playbackHeaders()
        let builder = PlaybackURLBuilder(
            baseURL: profile.baseURL,
            apiPathPrefix: profile.apiPathPrefix
        )
        let session = try PlaybackDecisionEngine.session(
            for: response,
            itemID: itemID,
            urlBuilder: builder,
            headers: headers
        )
        // URL 可能带认证参数(第 6 节的 api_key 退路),
        // 进日志前一律脱敏;同时也给「播的到底是哪条流」留了可诊断的痕迹。
        let safe = SecretRedactor.redactedDescription(of: session.plan.url)
        FileHandle.standardError.write(
            Data("[Playback] \(session.plan.method.rawValue) \(safe)\n".utf8))
        return session
    }
}
