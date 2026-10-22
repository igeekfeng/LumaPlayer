import Foundation

/// Emby 播放会话编排:取 PlaybackInfo → 决策 → 补认证头(MPV_INTEGRATION.md §1)。
///
/// ⛔ 不缓存凭据,每次从 `ServerConnection` 现取;⛔ 决策不放这里(`PlaybackDecisionEngine` 纯函数)。
actor PlaybackSessionCoordinator: PlaybackSessionPreparing {
    private let connection: ServerConnection
    private let itemID: String

    init(connection: ServerConnection, itemID: String) {
        self.connection = connection
        self.itemID = itemID
    }

    /// 抛 `EmbyAPIError`(401 由 `ServerConnection` 按 API_CONTRACT.md 2.5 处理)或 `PlaybackError`。
    ///
    /// - Parameter startTimeTicks: 转码起流位置(4.5)。会影响服务端决策,只在确知走转码后才传:
    ///   `PlayerViewModel` 先取一次会话,确认是转码再带它重取。
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
        // URL 可能带 api_key(第 6 节),进日志前脱敏
        let safe = SecretRedactor.redactedDescription(of: session.plan.url)
        FileHandle.standardError.write(
            Data("[Playback] \(session.plan.method.rawValue) \(safe)\n".utf8))
        return session
    }
}
