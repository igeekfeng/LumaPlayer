import Foundation

/// 本地文件夹来源的一次播放会话(`PlaybackSessionPreparing` 的本地实现)。
///
/// 地址就是文件本身(`file://`),交给内核直接按字节读 —— 拖动由内核自己做
/// (`seekStrategy = .clientSeek`),所以 `startTimeTicks` 永远不会带值进来。
actor LocalFileSessionPreparer: PlaybackSessionPreparing {

    private let file: BaiduPanFile
    private let rootPath: String
    /// 同目录里配好的外挂字幕(浏览页 / 队列装配时已用 `BaiduPanSubtitle.files` 配对)
    private let subtitleFiles: [BaiduPanFile]
    private let resolveRoot: @Sendable () async throws -> URL

    init(
        file: BaiduPanFile,
        source: LocalFolderSource,
        subtitleFiles: [BaiduPanFile] = [],
        resolveRoot: @escaping @Sendable () async throws -> URL
    ) {
        self.file = file
        self.rootPath = source.rootPath
        self.subtitleFiles = subtitleFiles
        self.resolveRoot = resolveRoot
    }

    func makeSession(startTimeTicks: Int64? = nil) async throws -> PlaybackSession {
        guard startTimeTicks == nil else {
            throw LocalFolderError.playbackUnsupported(
                "本地文件由播放内核直接拖动,没有「从指定位置起流」这一说。")
        }
        let root = try await resolveRoot()
        let url = try LocalFolderListing.fileURL(forPath: file.path, root: root, rootPath: rootPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalFolderError.fileMissing(name: file.name)
        }
        var session = try LocalFilePlaybackPlanner.session(
            file: file, url: url, playSessionID: UUID().uuidString)
        session.externalSubtitles = subtitleFiles.compactMap { subtitle in
            // 字幕文件不在了就不挂这一条(挂上也是一次失败提示),⛔ 不挡播放
            guard let subtitleURL = try? LocalFolderListing.fileURL(
                forPath: subtitle.path, root: root, rootPath: rootPath),
                  FileManager.default.fileExists(atPath: subtitleURL.path) else { return nil }
            return PlaybackSubtitle(
                url: subtitleURL, title: BaiduPanSubtitle.title(for: subtitle, video: file))
        }
        return session
    }
}

/// 本地文件 → 播放决策 → `PlaybackSession` 的映射(**纯函数,无 IO**)。
///
/// 与 `BaiduPanPlaybackPlanner` 同一个理由过 `PlaybackDecisionEngine`:「走哪条路」
/// 只有一张判定表。本地文件只有一条路 —— 声明「支持直连、不支持转码」,判定表必然
/// 给 `directStream`。⚠️ 这不是新增一种播放方式:`PlaybackPlan` 仍只有
/// `.directStream` / `.transcode` 两种(`CLAUDE.md`「架构主线」),本地文件就是一条
/// 地址为 `file://` 的直连流。
enum LocalFilePlaybackPlanner {

    static func session(
        file: BaiduPanFile, url: URL, playSessionID: String
    ) throws -> PlaybackSession {
        let decision = try PlaybackDecisionEngine.decision(for: EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: String(file.fsID),
                    // 容器名只用于统计展示,取扩展名(与百度同一口径)
                    container: file.fileExtension.isEmpty ? nil : file.fileExtension,
                    supportsDirectStream: true,
                    supportsTranscoding: false,
                    transcodingUrl: nil,
                    size: file.sizeBytes.flatMap { Int64(exactly: $0) },
                    mediaStreams: nil
                )
            ],
            playSessionID: playSessionID,
            errorCode: nil
        ))
        guard decision.method == .directStream else {
            // 判定表收到「只支持直连」却给了别的结论 —— 那是判定表的 bug,如实报
            throw LocalFolderError.playbackUnsupported("本地文件只能直接播放,判定却给了转码。")
        }
        return PlaybackSession(
            plan: .directStream(
                url: url,
                // 本地文件没有请求头可言
                headers: [:],
                playSessionID: decision.playSessionID,
                mediaSourceID: decision.source.id),
            mediaSource: decision.source,
            seekStrategy: .clientSeek
        )
    }
}
