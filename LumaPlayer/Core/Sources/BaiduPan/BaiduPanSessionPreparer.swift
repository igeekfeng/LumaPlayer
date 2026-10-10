import Foundation

/// 百度源的一次播放会话(`PlaybackSessionPreparing` 的百度实现)。
///
/// 与 `PlaybackSessionCoordinator` 的差别只在**一件事**:百度没有起流位置参数。
/// 所以 `startTimeTicks` 带值进来时**如实抛错**,而不是「把流重开一遍、从 0 开始」
/// —— 后者会让用户拖到 30 分钟却看到 0:00,还会把进度写成 0。
/// 播放页那边靠 `PlaybackSession.seekStrategy` 提前判掉,根本不会走到这里(§5.4)。
actor BaiduPanSessionPreparer: PlaybackSessionPreparing {

    private let connection: BaiduPanConnection
    private let file: BaiduPanFile
    /// 已经取到的流。缓存只是为了 `authoritativeDurationSeconds` 不必再取一次。
    private var cached: BaiduPanStreamSelection?

    init(connection: BaiduPanConnection, file: BaiduPanFile) {
        self.connection = connection
        self.file = file
    }

    func makeSession(startTimeTicks: Int64? = nil) async throws -> PlaybackSession {
        guard startTimeTicks == nil else {
            throw BaiduPanError.playbackUnsupported(
                "百度网盘的播放流不支持从指定位置起流(没有对位的起流参数)。")
        }
        if let cached { return cached.session }
        let selection = try await connection.playbackSelection(for: file)
        cached = selection
        return selection.session
    }

    var authoritativeDurationSeconds: Double? {
        cached?.durationSeconds
    }
}
