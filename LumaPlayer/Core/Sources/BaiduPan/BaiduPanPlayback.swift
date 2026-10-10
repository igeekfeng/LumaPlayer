import Foundation

// ⛔ 直连流**不要**套 `AVAssetResourceLoaderDelegate`(2026-10-10 真机实测,
// 逐条证据见文档 §11.10)。原方案是「自定义 scheme + 资源加载器,自己跟 302、
// 自己挂请求头」,依据是 §5.3 那条「Apple 不会把请求头带过跨主机跳转 → 31326」。
// 实测把这个前提和那条路本身都推翻了:
//
// 1. **`AVURLAssetHTTPHeaderFieldsKey` 的请求头能过跨主机 302。**
//    用真实 `dlink` 走普通 https + 该键:起播 ✓、播到 7.01 秒 ✓、
//    seek 到 604.93 秒 ✓、视频轨与音频轨都在 ✓。
//    而且第二跳(CDN)的 `sign` 是**跟 User-Agent 绑死**的 —— 同一 URL 换 UA
//    立刻 `31362 sign error`,所以那几次请求的 UA 确实带到了 CDN。
// 2. **自定义 scheme 那条路本身走不通。** 挂上资源加载器后 AVFoundation 不再按
//    区间读文件,而是发一条 `off=0 / len=<整份> / toEnd=true` 的请求(「从 0 读到
//    尾」)—— 400MB 的文件要先整份下完;而且子类把 HTTP 的 MIME 当 `contentType`
//    交回去时直接 `-11828 Cannot Open`(该字段要的是 UTI)。
//
// 结论:**直连流与 Emby 的 DirectStream 走同一条路** —— 普通 https 地址 +
// 认证请求头,内核自己跟跳转、自己按区间读。转码流本来就不受影响:
// HLS 分片是绝对 https 地址,资源加载器管不到它们。

/// 一条可播的百度网盘流:交给播放层的东西都在这里。
struct BaiduPanStreamSelection: Sendable, Equatable {
    let session: PlaybackSession
    /// 服务端(`filemetas`)给的总时长(秒)。**权威值**:
    /// 转码流在未转完时内核看到的只是已转码那一段(文档 §5.4)。
    let durationSeconds: Double?
    /// 这次是按哪条路线走的,给 UI / 日志用
    let route: Route

    enum Route: String, Sendable, Equatable {
        /// 原文件直连(`dlink` + Range)
        case directStream = "DirectStream"
        /// 云端转码成 HLS(`method=streaming`)
        case transcode = "Transcode"
    }
}

/// 百度元信息 → 播放决策 → `PlaybackSession` 的映射(**纯函数,无网络**)。
///
/// ## 为什么要把百度元信息拼成一份 `PlaybackInfo` 去问 Rust
///
/// 「这个文件本机放不放得了」只有一张表,那张表在 Rust 里
/// (`luma-emby::capability`,已由 `probe-avkit-capability.sh` 本机实测回填)。
/// 在这里另立一份判断 = 两条判定路径必然漂移,正是
/// `docs/DECISIONS/avkit-rust-rearchitecture.md` 反复警告的那类错误。
///
/// 所以这里**只做映射**:把
/// 容器(文件名后缀,§5.1 明确允许)、`dlink`、转码地址
/// 拼成一份 `PlaybackInfo` 的 JSON,过 FFI 交给同一个决策器。
///
/// ## 刻意**不**塞 `MediaStreams`
///
/// 百度不给轨道级的编码信息(只有 `media_info` 的时长/宽高)。若硬塞一条
/// 没有 `codec` 的轨,Rust 的能力表会把「缺编码」判成「不是原生编码」→
/// **每个文件都被推去转码**,连 mp4/h264 也一样。
/// 不塞的后果是视频/音频两维 `Unverifiable` —— 决策只按**容器**判,
/// 这是目前唯一有凭据的一维。**代价说清楚**:MP4 里装 DTS 这类「容器对、编码不对」
/// 的文件会被判成直连;真正的兜底是起播后的运行时核轨
/// (见 `tracks(for:)`),那条路会在轨消失时立刻报错而不是静默无声。
enum BaiduPanPlaybackPlanner {

    /// 先决策,拿到 `method` 之后再决定要不要探转码流。
    ///
    /// 拆成两步是**为了少发一次请求**:直连(容器原生支持)那条路
    /// 根本不需要问 `method=streaming`,而我们能用的调用配额极低
    /// (文档 §2.3:未审核应用 10 次/小时)。
    static func decision(
        file: BaiduPanFile,
        directStreamURL: URL,
        streamingURL: URL,
        durationSeconds: Double?,
        playSessionID: String
    ) throws -> PlaybackDecisionFfi {
        let infoJSON = try syntheticPlaybackInfoJSON(
            file: file,
            directStreamURL: directStreamURL,
            streamingURL: streamingURL,
            durationSeconds: durationSeconds,
            playSessionID: playSessionID
        )
        // ⛔ 唯一的判定入口:与 Emby 源走同一个函数、同一张能力表
        return try decidePlayback(playbackInfoJson: infoJSON)
    }

    /// 决策结果 → 可播的流。
    ///
    /// - Parameters:
    ///   - directStreamURL: 已经带好 `access_token` 的 `dlink`(§4.5 ②)
    ///   - streamingURL: 已带好 `access_token` 的 `method=streaming` 地址
    ///   - durationSeconds: `meta` 给的总时长(可能为 nil)
    static func selection(
        file: BaiduPanFile,
        decision: PlaybackDecisionFfi,
        directStreamURL: URL,
        streamingURL: URL,
        durationSeconds: Double?
    ) throws -> BaiduPanStreamSelection {
        let streams = tracks(for: file.kind)
        // ⚠️ 映射成 Emby 的形状**只为了喂播放层**(容器名 / 核轨口径 / 章节),
        // 不代表这是服务端的响应(见 `PlaybackSession` 的注释)。
        let mediaSource = EmbyMediaSource(
            id: String(file.fsID),
            container: file.fileExtension.isEmpty ? nil : file.fileExtension,
            supportsDirectStream: true,
            supportsTranscoding: true,
            transcodingUrl: streamingURL.absoluteString,
            mediaStreams: streams,
            chapters: [],
            directStreamUrl: directStreamURL.absoluteString
        )

        let route: BaiduPanStreamSelection.Route
        let plan: PlaybackPlan
        let seekStrategy: PlaybackSeekStrategy

        switch decision.method {
        case PlaybackMethod.directStream.rawValue:
            route = .directStream
            // ⛔ 普通 https 原样交给内核(理由见文件头):不套自定义 scheme。
            // 认证靠请求头,而这个 UA 与 CDN 的 sign 绑死,⛔ 不能换。
            plan = .directStream(
                url: directStreamURL,
                headers: ["User-Agent": BaiduPanUserAgent.download],
                playSessionID: decision.playSessionId,
                mediaSourceID: decision.mediaSourceId
            )
            seekStrategy = .clientSeek

        case PlaybackMethod.transcode.rawValue:
            route = .transcode
            plan = .transcode(
                url: streamingURL,
                headers: ["User-Agent": BaiduPanUserAgent.streaming],
                playSessionID: decision.playSessionId,
                mediaSourceID: decision.mediaSourceId
            )
            // ⛔ 不假装能拖:`method=streaming` 没有起流位置参数,
            // 重新请求只会从头开始(§5.4 第 3 条)。
            seekStrategy = .unsupported(reason: "云端转码流不支持拖动进度")

        default:
            // 取值只有上面两个。走到这里说明 FFI 两侧字符串漂移了 ——
            // ⛔ 不按「大概是转码」糊过去。
            throw PlaybackError.unknownDecisionMethod(name: decision.method)
        }

        return BaiduPanStreamSelection(
            session: PlaybackSession(
                plan: plan,
                mediaSource: mediaSource,
                decision: decision,
                seekStrategy: seekStrategy
            ),
            durationSeconds: durationSeconds,
            route: route
        )
    }

    /// 拼一份 `PlaybackInfo` 响应形状的 JSON(字段名与 Rust 侧 `models.rs` 的
    /// 显式 `rename` 一致,证据是 `Scripts/verify-avkit-decision.sh` 的 fixture)。
    static func syntheticPlaybackInfoJSON(
        file: BaiduPanFile,
        directStreamURL: URL,
        streamingURL: URL,
        durationSeconds: Double?,
        playSessionID: String
    ) throws -> String {
        let source = SyntheticPlaybackInfo.Source(
            id: String(file.fsID),
            container: file.fileExtension.isEmpty ? nil : file.fileExtension,
            supportsDirectStream: true,
            supportsTranscoding: true,
            directStreamURL: directStreamURL.absoluteString,
            transcodingURL: streamingURL.absoluteString,
            // 转码交付形态实测只能是 HLS(文档 §8.5 实测一)
            transcodingSubProtocol: "hls",
            runTimeTicks: durationSeconds.map(TickConverter.ticks(fromSeconds:))
        )
        let info = SyntheticPlaybackInfo(playSessionID: playSessionID, mediaSources: [source])
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(info)
            guard let json = String(data: data, encoding: .utf8) else {
                throw PlaybackError.urlConstructionFailed
            }
            return json
        } catch {
            throw PlaybackError.urlConstructionFailed
        }
    }

    /// 起播后核轨要用的「预期存在的轨」。
    ///
    /// ## 判据来自哪
    ///
    /// `category`(`1` 视频 / `2` 音频)是**服务端给的**,不是猜的:
    /// 说它是视频,那它就该有视频轨与音频轨。
    ///
    /// ## 音频维的取舍(明说)
    ///
    /// 视频文件**一律要求音频轨**。代价是「无音轨的默片」会被判成缺轨而报错;
    /// 换来的是「有画面没声音」这类静默失败能被抓住 —— 那正是
    /// `TrackExpectation` 存在的理由(文档 §2.1 实测:R12 静默删轨不报错)。
    /// 方向按能力表那条原则取:**宁可报错,也不假装放得了**。
    static func tracks(for kind: BaiduPanFileKind) -> [EmbyMediaStream] {
        switch kind {
        case .video:
            return [stream(index: 0, type: "Video"), stream(index: 1, type: "Audio")]
        case .audio:
            return [stream(index: 0, type: "Audio")]
        case .other:
            // 不可播的文件根本走不到这里(UI 不给入口);真走到了就不要求任何轨
            return []
        }
    }

    /// ⚠️ `codec` 一律 nil:`TrackExpectation` 只看 `type`,
    /// 而这里也**没有**编码信息可填 —— ⛔ 不填一个猜的 `h264` 进去。
    private static func stream(index: Int, type: String) -> EmbyMediaStream {
        EmbyMediaStream(
            index: index,
            type: type,
            codec: nil,
            language: nil,
            isDefault: nil,
            isTextSubtitleStream: nil,
            isExternal: nil,
            displayTitle: nil,
            title: nil,
            width: nil,
            height: nil,
            channels: nil
        )
    }
}

/// 给 Rust 决策器看的 `PlaybackInfo`。字段名逐个显式 `rename` 成 Emby 的
/// PascalCase 拼写(与 `RustCore` 的 `serde` 配置同一口径)。
private struct SyntheticPlaybackInfo: Encodable {
    let playSessionID: String
    let mediaSources: [Source]

    struct Source: Encodable {
        let id: String
        let container: String?
        let supportsDirectStream: Bool
        let supportsTranscoding: Bool
        let directStreamURL: String
        let transcodingURL: String
        let transcodingSubProtocol: String
        let runTimeTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case container = "Container"
            case supportsDirectStream = "SupportsDirectStream"
            case supportsTranscoding = "SupportsTranscoding"
            case directStreamURL = "DirectStreamUrl"
            case transcodingURL = "TranscodingUrl"
            case transcodingSubProtocol = "TranscodingSubProtocol"
            case runTimeTicks = "RunTimeTicks"
        }
    }

    enum CodingKeys: String, CodingKey {
        case playSessionID = "PlaySessionId"
        case mediaSources = "MediaSources"
    }
}
