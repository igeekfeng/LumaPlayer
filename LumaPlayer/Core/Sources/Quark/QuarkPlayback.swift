import Foundation

// ⛔ 直连流不要套资源加载代理层或自建 scheme:夸克的 `download_url` 是普通 https,内核自己跟跳转、按 `Range` 读。
// TV 端直链是自带签名的 CDN 地址,参考实现都不挂头(`docs/QUARK_API.md` §6.1),所以 `headers` 恒空。

struct QuarkStreamSelection: Sendable, Equatable {
    let session: PlaybackSession
    /// 文件总时长(秒)。夸克列表里的 `duration` 单位未实测(§5.1),所以这里恒为 nil,
    /// 由内核自己探;保留字段是为了与另外两家的调用形状一致。
    let durationSeconds: Double?
}

/// 夸克直链 → 播放决策 → `PlaybackSession` 的映射(纯函数,无网络)。
///
/// 判定表只有一张(`PlaybackDecisionEngine`),⛔ 不另立判断:这里把文件拼成
/// `EmbyPlaybackInfoResponse` 的形状去问它。只借形状,地址仍由夸克给(见 `selection(...)`)。
///
/// `supportsTranscoding: false` 是事实:`method=streaming` 的转码直链不是原画、还要兜
/// 「取不到 url 就回退」的分支(§6.2),本项目不实现第二条路径。
/// 不填 `MediaStreams`:TV 端不给轨道级编码信息,⛔ 不虚构轨道声明。
enum QuarkPlaybackPlanner {

    /// - Parameters:
    ///   - link: `QuarkConnection.playbackLink(forPath:)` 的结果
    ///   - playSessionID: 夸克没有会话上报,只喂判定表与日志,不发给任何人
    static func selection(
        file: BaiduPanFile,
        link: QuarkDownloadLink,
        playSessionID: String
    ) throws -> QuarkStreamSelection {
        let decision = try PlaybackDecisionEngine.decision(
            for: response(file: file, link: link, playSessionID: playSessionID))

        // ⛔ 地址原样采用,不经 `PlaybackURLBuilder`:`URLComponents.queryItems` 往返会改签名参数
        //    (与百度直链 `31362`、115 直链 `k` 签名同一个坑)
        let plan = PlaybackPlan.directStream(
            url: link.url,
            headers: link.headers,
            playSessionID: decision.playSessionID,
            mediaSourceID: decision.source.id
        )
        return QuarkStreamSelection(
            session: PlaybackSession(
                plan: plan,
                mediaSource: decision.source,
                // 直链是静态文件,`Range` 由内核自己发
                seekStrategy: .clientSeek
            ),
            durationSeconds: nil
        )
    }

    /// 合成的 `PlaybackInfo` 响应形状。⛔ 不是服务端响应,任何 Emby 请求都不许拿它当依据。
    static func response(
        file: BaiduPanFile,
        link: QuarkDownloadLink,
        playSessionID: String
    ) -> EmbyPlaybackInfoResponse {
        EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: String(file.fsID),
                    // 容器取文件名后缀,只作展示 / 诊断
                    container: file.fileExtension.isEmpty ? nil : file.fileExtension,
                    supportsDirectStream: true,
                    supportsTranscoding: false,
                    transcodingUrl: nil,
                    mediaStreams: nil
                )
            ],
            playSessionID: playSessionID,
            errorCode: nil
        )
    }
}
