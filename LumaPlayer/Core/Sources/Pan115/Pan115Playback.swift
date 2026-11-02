import Foundation

// ⛔ 直连流不要套资源加载代理层或自建 scheme:115 的 CDN 地址是普通 https,内核自己跟跳转、按 `Range` 读。
// 认证靠请求头(`User-Agent`,有时还要 `Cookie`),由 `Pan115DownloadLink.headers` 给出,⛔ 不能改。

struct Pan115StreamSelection: Sendable, Equatable {
    let session: PlaybackSession
    /// 文件总时长(秒)。115 的列表接口不给时长(`docs/PAN115_API.md` §3),
    /// 所以这里恒为 nil,由内核自己探;保留字段是为了与百度那套的调用形状一致。
    let durationSeconds: Double?
}

/// 115 直链 → 播放决策 → `PlaybackSession` 的映射(纯函数,无网络)。
///
/// 115 只有「原文件直连」一种播法(§4):转码 m3u8 要额外消耗 115 的转码资源、还会把 m3u8 内的
/// 分片地址绑到取链时的 UA 上,而直链交给 libmpv 直接播就够。所以这里不拼转码地址,
/// `supportsTranscoding` 给 `false` —— 判定表据此只会选 DirectStream。
///
/// 不填 `MediaStreams`:115 不给轨道级编码信息,⛔ 不虚构轨道声明。
enum Pan115PlaybackPlanner {

    /// - Parameters:
    ///   - link: `Pan115Connection.playbackLink(pickCode:)` 的结果(地址 + 要求的请求头)
    ///   - playSessionID: 115 没有会话上报,只喂判定表与日志,不发给任何人
    static func selection(
        file: BaiduPanFile,
        link: Pan115DownloadLink,
        playSessionID: String
    ) throws -> Pan115StreamSelection {
        let decision = try PlaybackDecisionEngine.decision(for: response(
            file: file, link: link, playSessionID: playSessionID))

        // ⛔ 地址原样采用,不经 `PlaybackURLBuilder`:`URLComponents.queryItems` 往返会把
        //    `%2B` 改成 `+`,115 直链的 `k` 签名一变就是 403(§4.3)
        let plan = PlaybackPlan.directStream(
            url: link.url,
            headers: link.headers,
            playSessionID: decision.playSessionID,
            mediaSourceID: decision.source.id
        )

        return Pan115StreamSelection(
            session: PlaybackSession(
                plan: plan,
                mediaSource: decision.source,
                // 直链是静态文件,`Range` 由内核自己发 —— 与百度直连流同一条路径
                seekStrategy: .clientSeek
            ),
            durationSeconds: nil
        )
    }

    /// 合成的 `PlaybackInfo` 响应形状。⛔ 不是服务端响应,任何 Emby 请求都不许拿它当依据。
    ///
    /// `supportsTranscoding: false` 是事实:本项目不实现 115 的转码流(§4.2 只是记录备查)。
    static func response(
        file: BaiduPanFile,
        link: Pan115DownloadLink,
        playSessionID: String
    ) -> EmbyPlaybackInfoResponse {
        EmbyPlaybackInfoResponse(
            mediaSources: [
                EmbyMediaSource(
                    id: String(file.fsID),
                    // 容器取文件名后缀(§3),只作展示 / 诊断
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
