import Foundation

// ⛔ 直连流**不要**套 `AVAssetResourceLoaderDelegate` 之类的代理层,也不要自建 scheme:
// 百度的 `dlink` 就是普通 https 地址,播放内核自己跟跳转、自己按 `Range` 读。
// 这里留一段说明是为了挡住「为了挂请求头而套一层加载器」的冲动 ——
// 认证靠请求头(`User-Agent`),而这个 UA 与 CDN 的 sign 绑死,⛔ 不能换。

/// 一条可播的百度网盘流:交给播放层的东西都在这里。
struct BaiduPanStreamSelection: Sendable, Equatable {
    let session: PlaybackSession
    /// 服务端(`filemetas`)给的总时长(秒)。**权威值**:
    /// 转码流在未转完时内核看到的只是已转码那一段。
    let durationSeconds: Double?
    /// 这次是按哪条路线走的,给 UI / 日志用
    let route: Route

    enum Route: String, Sendable, Equatable {
        /// 原文件直连(`dlink` + `Range`)
        case directStream = "DirectStream"
        /// 云端转码成 HLS(`method=streaming`)
        case transcode = "Transcode"
    }
}

/// 百度元信息 → 播放决策 → `PlaybackSession` 的映射(**纯函数,无网络**)。
///
/// ## 为什么把百度元信息拼成一份 `PlaybackInfo` 去问同一个决策器
///
/// 「这个文件本机放不放得了、走哪条路」只有一张判定表,那张表在
/// `PlaybackDecisionEngine` 里。在这里另立一份判断 = 两条判定路径必然漂移。
///
/// 所以这里**只做映射**:把百度文件 + `dlink` + 转码地址拼成一份
/// `EmbyPlaybackInfoResponse` 的形状,过 `PlaybackDecisionEngine.decision(for:)`
/// 拿判定结论。⚠️ **只借形状,不借地址规则**:地址仍由百度自己给
/// (理由见 `selection(...)`)。
///
/// ## 不塞 `MediaStreams`
///
/// 百度不给轨道级的编码信息。`main` 也没有 exp 分支那套核轨守卫
/// (`TrackExpectation` 是 AVKit 才要的:`AVFoundation` 遇到不认识的编码会
/// **静默删轨**),所以这里既不填编码、也不虚构一条「应该有 1 视频 + 1 音频轨」
/// 的声明 —— 那是没有消费者的伪造数据(CLAUDE.md 硬规则 4)。
enum BaiduPanPlaybackPlanner {

    /// 映射 + 决策 + 拼会话。
    ///
    /// - Parameters:
    ///   - directStreamURL: 已经带好 `access_token` 的 `dlink`(`BAIDU_PAN_API.md` §2.2)
    ///   - streamingURL: 已带好 `access_token` 的 `method=streaming` 地址
    ///   - durationSeconds: `filemetas` 给的总时长(可能为 nil)
    ///   - playSessionID: 百度没有会话上报,这个 id 只喂判定表与日志,
    ///     ⛔ 不会发给任何人
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
            // ⛔ 地址**原样**采用,不经 `PlaybackURLBuilder`:那个构造器会走
            //    `URLComponents.queryItems` 过滤 `api_key`,而那一趟往返会把
            //    `%2B` 重编码成 `+`(2026-10-11 实测),`dlink` 的签名一变
            //    就是 `31362 签名错误`(`BAIDU_PAN_API.md` §5)。
            //    认证靠请求头,而这个 UA 与 CDN 的 sign 绑死,⛔ 不能换。
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
            // ⛔ 不假装能拖:`method=streaming` 没有起流位置参数,
            //    重新请求只会从头开始(`BAIDU_PAN_API.md` §2.3)。
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

    /// 把一条百度文件合成为一份 `PlaybackInfo` 响应**形状**。
    ///
    /// ⚠️ 合成的 `EmbyMediaSource` **不是服务端响应**:它只喂判定表与播放层
    /// (容器名 / 「被选中那条源」这个概念)。⛔ 任何一条 Emby 请求都不许拿它当依据。
    ///
    /// `supportsDirectStream` / `supportsTranscoding` 都是**事实**而不是猜测:
    /// 走到这里时 `dlink` 已经拿到(直连可用),而 `method=streaming` 是百度
    /// 标准提供的转码出口。选定哪条由判定表按这两项决定。
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
                    // 容器取文件名后缀 —— `BAIDU_PAN_API.md` §4 明确允许这一路
                    // (百度只在 `media_info` 里给编码信息,而实测那个字段不存在),
                    // 这里要的也只是「容器名」这个展示/诊断口径
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
