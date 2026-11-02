import Foundation

/// `PlaybackSessionPreparing` 的 115 实现。
///
/// 115 的直链是**静态文件**,没有起流位置参数,所以 `startTimeTicks` 带值时如实抛错,
/// ⛔ 不从 0 重开(会把进度写成 0)。播放页靠 `PlaybackSession.seekStrategy` 提前判掉,
/// 正常不会走到这里。
///
/// ⚠️ 直链有有效期(`t` 参数,§4.3),过期后 CDN 回 403。所以**每次 `makeSession` 都重新取一次链**:
/// 播放页的「重试」会再调一次本方法,拿缓存里的旧地址只会再 403 一次。
/// 缓存只用于 `authoritativeDurationSeconds`(那里不该触发网络)。
actor Pan115SessionPreparer: PlaybackSessionPreparing {

    private let connection: Pan115Connection
    private let file: BaiduPanFile
    /// 列目录时缓存的 `pick_code`。缓存里没有时**列一次所在目录**补上 —— 比让播放失败好,
    /// 而且目录刚列过就基本不会走到这条路(限速见 §6)。
    private let pickCodes: Pan115PickCodeCache
    /// 同目录的字幕文件。配对规则与百度共用 `BaiduPanSubtitle`(纯文件名匹配,与网盘无关)。
    private let subtitleFiles: [BaiduPanFile]
    /// 最近一次取到的时长。115 的列表接口不给时长(§3),所以这里恒为 nil ——
    /// 保留字段是为了与百度那套的调用形状一致。
    private var cachedDuration: Double?

    init(
        connection: Pan115Connection,
        file: BaiduPanFile,
        pickCodes: Pan115PickCodeCache,
        subtitleFiles: [BaiduPanFile] = []
    ) {
        self.connection = connection
        self.file = file
        self.pickCodes = pickCodes
        self.subtitleFiles = subtitleFiles
    }

    func makeSession(startTimeTicks: Int64? = nil) async throws -> PlaybackSession {
        guard startTimeTicks == nil else {
            throw Pan115Error.playbackUnsupported(
                "115 网盘的播放流不支持从指定位置起流(没有对位的起流参数)。")
        }
        // ⛔ 不复用上次的会话:直链是死 URL,重试时必须换一条新的
        let pickCode = try await resolvePickCode(for: file)
        let link = try await connection.playbackLink(pickCode: pickCode)
        let selection = try Pan115PlaybackPlanner.selection(
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

    /// 先查缓存;没有就列一次父目录,把整层 `pick_code` 一起补进缓存。
    private func resolvePickCode(for target: BaiduPanFile) async throws -> String {
        if let cached = await pickCodes.pickCode(for: target.fsID) { return cached }
        let directory = BaiduPanPath.directory(ofFilePath: target.path)
        let entries = try await connection.files(in: directory)
        var mapping: [UInt64: String] = [:]
        for entry in entries {
            guard !entry.isDirectory, let pickCode = entry.pickCode, !pickCode.isEmpty,
                  let id = entry.numericID else { continue }
            mapping[id] = pickCode
        }
        await pickCodes.store(mapping)
        guard let pickCode = mapping[target.fsID] else {
            throw Pan115Error.pickCodeMissing(target.name)
        }
        return pickCode
    }

    /// 115 没有批量取直链的接口(`downurl` 虽收逗号分隔的多个 `pickcode`,但响应里
    /// fileID 与请求顺序的对应关系未实测,⛔ 不猜),所以这里逐条取。字幕一般 1-2 个,可接受。
    private func externalSubtitles() async -> [PlaybackSubtitle] {
        guard !subtitleFiles.isEmpty else { return [] }
        var subtitles: [PlaybackSubtitle] = []
        for subtitle in subtitleFiles {
            // 字幕取不到就跳过:它不影响正片播放,⛔ 不要为它让整次起播失败
            guard let pickCode = try? await resolvePickCode(for: subtitle),
                  let link = try? await connection.playbackLink(pickCode: pickCode)
            else { continue }
            subtitles.append(PlaybackSubtitle(
                url: link.url,
                title: BaiduPanSubtitle.title(for: subtitle, video: file)
            ))
        }
        return subtitles
    }
}
