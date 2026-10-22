import Foundation

/// `PlaybackSessionPreparing` 的本地文件夹实现。地址就是 `file://`,拖动由内核做(`.clientSeek`),
/// 所以 `startTimeTicks` 正常不会带值。
actor LocalFileSessionPreparer: PlaybackSessionPreparing {

    private let file: BaiduPanFile
    private let rootPath: String
    /// 调用方已用 `BaiduPanSubtitle.files` 配对好
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
            // 字幕文件不在了就跳过,⛔ 不挡播放
            guard let subtitleURL = try? LocalFolderListing.fileURL(
                forPath: subtitle.path, root: root, rootPath: rootPath),
                  FileManager.default.fileExists(atPath: subtitleURL.path) else { return nil }
            return PlaybackSubtitle(
                url: subtitleURL, title: BaiduPanSubtitle.title(for: subtitle, video: file))
        }
        return session
    }
}

/// 本地文件 → 播放决策 → `PlaybackSession`(纯函数,无 IO)。同 `BaiduPanPlaybackPlanner`,
/// 也过唯一的判定表 `PlaybackDecisionEngine`;本地文件就是一条 `file://` 的直连流,⛔ 不新增播放方式。
enum LocalFilePlaybackPlanner {

    static func session(
        file: BaiduPanFile, url: URL, playSessionID: String
    ) throws -> PlaybackSession {
        let decision = try PlaybackDecisionEngine.decision(for: EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: String(file.fsID),
                    // 容器名只用于展示,取扩展名
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
            // 走到这里是判定表的 bug,如实报
            throw LocalFolderError.playbackUnsupported("本地文件只能直接播放,判定却给了转码。")
        }
        return PlaybackSession(
            plan: .directStream(
                url: url,
                headers: [:],
                playSessionID: decision.playSessionID,
                mediaSourceID: decision.source.id),
            mediaSource: decision.source,
            seekStrategy: .clientSeek
        )
    }
}
