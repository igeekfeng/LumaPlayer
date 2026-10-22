import Foundation

/// `PlaybackSessionPreparing` 的百度实现。
///
/// 百度没有起流位置参数,`startTimeTicks` 带值时如实抛错,⛔ 不从 0 重开(会把进度写成 0)。
/// 播放页靠 `PlaybackSession.seekStrategy` 提前判掉,正常不会走到。
actor BaiduPanSessionPreparer: PlaybackSessionPreparing {

    private let connection: BaiduPanConnection
    private let file: BaiduPanFile
    /// 调用方用 `BaiduPanSubtitle.files` 配对好的外挂字幕。由调用方传是因为它手上已有目录列表,
    /// 这里再列一次就多一次请求(配额见 §7)。
    private let subtitleFiles: [BaiduPanFile]
    /// 缓存是为了 `authoritativeDurationSeconds` 不必再取一次。
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
        // 字幕地址另换一次 `dlink`(一次批量请求)。失败不抛,由播放页挂载时如实提示
        session.externalSubtitles = await externalSubtitles()
        return session
    }

    var authoritativeDurationSeconds: Double? {
        cached?.durationSeconds
    }

    /// `metaInfo` 失败只返回空表,这里不再包一层。
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
