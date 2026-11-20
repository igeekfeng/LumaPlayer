import Foundation

/// `PlaybackSessionPreparing` 的夸克实现。
///
/// 夸克的直链是**静态文件**,没有起流位置参数,所以 `startTimeTicks` 带值时如实抛错,
/// ⛔ 不从 0 重开(会把进度写成 0)。播放页靠 `PlaybackSession.seekStrategy` 提前判掉,
/// 正常不会走到这里。
///
/// ⚠️ 直链有效期未知(§8),所以**每次 `makeSession` 都重新取一次链**:播放页的「重试」会再调一次,
/// 拿缓存里的旧地址只会再 403 一次。
actor QuarkSessionPreparer: PlaybackSessionPreparing {

    private let connection: QuarkConnection
    private let file: BaiduPanFile
    /// 同目录的字幕文件。配对规则与百度共用 `BaiduPanSubtitle`(纯文件名匹配,与网盘无关)。
    private let subtitleFiles: [BaiduPanFile]
    /// 最近一次取到的时长。夸克列表不给可用时长(§5.1),所以恒为 nil ——
    /// 保留字段是为了与另外两家的调用形状一致。
    private var cachedDuration: Double?

    init(
        connection: QuarkConnection,
        file: BaiduPanFile,
        subtitleFiles: [BaiduPanFile] = []
    ) {
        self.connection = connection
        self.file = file
        self.subtitleFiles = subtitleFiles
    }

    func makeSession(startTimeTicks: Int64? = nil) async throws -> PlaybackSession {
        guard startTimeTicks == nil else {
            throw QuarkError.playbackUnsupported(
                "夸克网盘的播放流不支持从指定位置起流(没有对位的起流参数)。")
        }
        // ⛔ 不复用上次的会话:直链是死 URL,重试时必须换一条新的
        let link = try await connection.playbackLink(forPath: file.path)
        let selection = try QuarkPlaybackPlanner.selection(
            file: file,
            link: link,
            playSessionID: UUID().uuidString
        )
        cachedDuration = selection.durationSeconds
        var session = selection.session
        // 字幕地址另取一次直链。失败不抛,由播放页挂载时如实提示
        session.externalSubtitles = await externalSubtitles()
        return session
    }

    var authoritativeDurationSeconds: Double? {
        cachedDuration
    }

    /// 逐条取(夸克没有批量取直链的接口)。字幕一般 1-2 个,可接受;
    /// 取不到就跳过 —— 它不影响正片播放,⛔ 不要为它让整次起播失败。
    private func externalSubtitles() async -> [PlaybackSubtitle] {
        guard !subtitleFiles.isEmpty else { return [] }
        var subtitles: [PlaybackSubtitle] = []
        for subtitle in subtitleFiles {
            guard let link = try? await connection.playbackLink(forPath: subtitle.path)
            else { continue }
            subtitles.append(PlaybackSubtitle(
                url: link.url,
                title: BaiduPanSubtitle.title(for: subtitle, video: file)
            ))
        }
        return subtitles
    }
}
