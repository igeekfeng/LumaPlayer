import Foundation

// ⛔ 直连流不要套资源加载代理层或自建 scheme:`dlink` 是普通 https 地址,内核自己跟跳转、按 `Range` 读。
// 认证靠 `User-Agent` 请求头,它与 CDN 的 sign 绑死,⛔ 不能换。

struct BaiduPanStreamSelection: Sendable, Equatable {
    let session: PlaybackSession
    /// `filemetas` 给的总时长(秒),权威值:转码流未转完时内核只看到已转码那一段。
    let durationSeconds: Double?
    let route: Route

    enum Route: String, Sendable, Equatable {
        /// 原文件直连(`dlink` + `Range`)
        case directStream = "DirectStream"
        /// 云端转码成 HLS(`method=streaming`)
        case transcode = "Transcode"
    }
}

/// 百度元信息 → 播放决策 → `PlaybackSession` 的映射(纯函数,无网络)。
///
/// 判定表只有一张(`PlaybackDecisionEngine`),⛔ 不另立判断:这里把百度文件拼成
/// `EmbyPlaybackInfoResponse` 的形状去问它。只借形状,地址仍由百度给(见 `selection(...)`)。
///
/// 不填 `MediaStreams`:百度不给轨道级编码信息,⛔ 不虚构轨道声明。
enum BaiduPanPlaybackPlanner {

    /// - Parameters:
    ///   - directStreamURL: 已带 `access_token` 的 `dlink`(`BAIDU_PAN_API.md` §2.2)
    ///   - streamingURL: 已带 `access_token` 的 `method=streaming` 地址
    ///   - playSessionID: 百度没有会话上报,只喂判定表与日志,不发给任何人
    static func selection(
        file: BaiduPanFile,
        directStreamURL: URL,
        streamingURL: URL,
        durationSeconds: Double?,
        playSessionID: String
    ) throws -> BaiduPanStreamSelection {
        let decision = try PlaybackDecisionEngine.decision(for: response(
            file: file,
            directStreamURL: directStreamURL,
            streamingURL: streamingURL,
            playSessionID: playSessionID
        ))

        let route: BaiduPanStreamSelection.Route
        let plan: PlaybackPlan
        let seekStrategy: PlaybackSeekStrategy

        switch decision.method {
        case .directStream:
            route = .directStream
            // ⛔ 地址原样采用,不经 `PlaybackURLBuilder`:`URLComponents.queryItems` 往返会把
            //    `%2B` 改成 `+`,签名一变就是 `31362`(`BAIDU_PAN_API.md` §5)
            plan = .directStream(
                url: directStreamURL,
                headers: ["User-Agent": BaiduPanUserAgent.download],
                playSessionID: decision.playSessionID,
                mediaSourceID: decision.source.id
            )
            seekStrategy = .clientSeek

        case .transcode:
            route = .transcode
            plan = .transcode(
                url: streamingURL,
                headers: ["User-Agent": BaiduPanUserAgent.streaming],
                playSessionID: decision.playSessionID,
                mediaSourceID: decision.source.id
            )
            // ⛔ 不假装能拖:`method=streaming` 没有起流位置参数(`BAIDU_PAN_API.md` §2.3)
            seekStrategy = .unsupported(reason: "云端转码流不支持拖动进度")
        }

        return BaiduPanStreamSelection(
            session: PlaybackSession(
                plan: plan,
                mediaSource: decision.source,
                seekStrategy: seekStrategy
            ),
            durationSeconds: durationSeconds,
            route: route
        )
    }

    /// 合成的 `PlaybackInfo` 响应形状。⛔ 不是服务端响应,任何 Emby 请求都不许拿它当依据。
    /// 两个 `supports…` 都是事实:`dlink` 已拿到,`method=streaming` 是百度标准转码出口。
    static func response(
        file: BaiduPanFile,
        directStreamURL: URL,
        streamingURL: URL,
        playSessionID: String
    ) -> EmbyPlaybackInfoResponse {
        EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: String(file.fsID),
                    // 容器取文件名后缀(`BAIDU_PAN_API.md` §4),只作展示 / 诊断
                    container: file.fileExtension.isEmpty ? nil : file.fileExtension,
                    supportsDirectStream: true,
                    supportsTranscoding: true,
                    transcodingUrl: streamingURL.absoluteString,
                    mediaStreams: nil
                )
            ],
            playSessionID: playSessionID,
            errorCode: nil
        )
    }
}
