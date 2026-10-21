import Foundation

/// 百度来源的一次播放会话(`PlaybackSessionPreparing` 的百度实现)。
///
/// 与 `PlaybackSessionCoordinator` 的差别只在**一件事**:百度没有起流位置参数。
/// 所以 `startTimeTicks` 带值进来时**如实抛错**,而不是「把流重开一遍、从 0 开始」
/// —— 后者会让用户拖到 30 分钟却看到 0:00,还会把进度写成 0。
/// 播放页那边靠 `PlaybackSession.seekStrategy` 提前判掉,根本不会走到这里。
actor BaiduPanSessionPreparer: PlaybackSessionPreparing {

    private let connection: BaiduPanConnection
    private let file: BaiduPanFile
    /// 同目录里属于这条视频的外挂字幕(已由调用方用 `BaiduPanSubtitle.files` 配对好)。
    ///
    /// ⚠️ 为什么由调用方传:**配对不需要网络**(同目录文件列表在浏览页 / 队列装配时
    /// 就已经在手上),而在这里重新列一次目录就是多一次百度请求(配额见 §7)。
    private let subtitleFiles: [BaiduPanFile]
    /// 已经取到的流。缓存只是为了 `authoritativeDurationSeconds` 不必再取一次。
    private var cached: BaiduPanStreamSelection?

    init(
        connection: BaiduPanConnection,
        file: BaiduPanFile,
        subtitleFiles: [BaiduPanFile] = []
    ) {
        self.connection = connection
        self.file = file
        self.subtitleFiles = subtitleFiles
    }

    func makeSession(startTimeTicks: Int64? = nil) async throws -> PlaybackSession {
        guard startTimeTicks == nil else {
            throw BaiduPanError.playbackUnsupported(
                "百度网盘的播放流不支持从指定位置起流(没有对位的起流参数)。")
        }
        if let cached { return cached.session }
        let selection = try await connection.playbackSelection(for: file)
        cached = selection
        var session = selection.session
        // 字幕地址要单独换一次 `dlink`(一次批量请求;没有字幕文件时零请求)。
        // 失败不抛:字幕挂不上不该让整场播不了 —— 由播放页在挂载时如实提示。
        session.externalSubtitles = await externalSubtitles()
        return session
    }

    var authoritativeDurationSeconds: Double? {
        cached?.durationSeconds
    }

    /// 把配对好的字幕文件换成可加载的地址。
    ///
    /// ⚠️ 用**同一个** `metaInfo` 批量接口:它本来就带 `dlink`,而且失败只返回空表
    /// (`BaiduPanConnection.metaInfo` 的「失败不抛」)—— 这里不需要再包一层。
    private func externalSubtitles() async -> [PlaybackSubtitle] {
        guard !subtitleFiles.isEmpty else { return [] }
        let meta = await connection.metaInfo(for: subtitleFiles.map(\.fsID))
        return subtitleFiles.compactMap { subtitle in
            guard let url = meta.downloadURLs[subtitle.fsID] else { return nil }
            return PlaybackSubtitle(
                url: url,
                title: BaiduPanSubtitle.title(for: subtitle, video: file)
            )
        }
    }
}
