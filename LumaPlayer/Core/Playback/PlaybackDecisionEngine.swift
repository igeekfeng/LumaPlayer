import Foundation

/// 播放路径的判定结果(API_CONTRACT.md 4.2/4.5)。
///
/// ⛔ LumaPlayer **没有** `directPlay`:客户端访问不到服务端的文件系统,
/// 「用 HTTP 拉原始文件」在 Emby 语义里叫 Direct Stream。
/// 若将来支持本地挂载,再新增 `case directPlay(fileURL:)` —— 现在不预留。
enum PlaybackPlan: Sendable, Equatable {
    /// `static=true`:服务端原样吐原始文件,客户端可自由 seek
    case directStream(url: URL, headers: [String: String], playSessionID: String, mediaSourceID: String)
    /// 服务端转码(地址来自 `MediaSource.TranscodingUrl`)。
    /// ⚠️ 转码模式下**不能**用 mpv 的 seek:必须停流 + `StartTimeTicks` 重新起流(4.5)。
    case transcode(url: URL, headers: [String: String], playSessionID: String, mediaSourceID: String)

    var url: URL {
        switch self {
        case .directStream(let url, _, _, _), .transcode(let url, _, _, _): return url
        }
    }

    var headers: [String: String] {
        switch self {
        case .directStream(_, let headers, _, _), .transcode(_, let headers, _, _): return headers
        }
    }

    var playSessionID: String {
        switch self {
        case .directStream(_, _, let id, _), .transcode(_, _, let id, _): return id
        }
    }

    var mediaSourceID: String {
        switch self {
        case .directStream(_, _, _, let id), .transcode(_, _, _, let id): return id
        }
    }

    var method: PlaybackMethod {
        switch self {
        case .directStream: return .directStream
        case .transcode: return .transcode
        }
    }
}

/// 上报与展示用的播放方式(API_CONTRACT.md 4.2 的 `PlayMethod` 列)。
enum PlaybackMethod: String, Sendable, Equatable {
    case directStream = "DirectStream"
    case transcode = "Transcode"

    /// UI 上显示的名字
    var displayName: String {
        switch self {
        case .directStream: return "直接串流"
        case .transcode: return "服务端转码"
        }
    }
}

/// 播放决策失败的原因(都要给出**可解释**的文案)。
enum PlaybackError: Error, Equatable, Sendable {
    /// 服务端明确拒绝(响应里 `ErrorCode` 非空)
    case serverRejected(code: String)
    /// 响应里没有任何 MediaSource
    case noMediaSource
    /// 选中的 MediaSource 既不能 Direct Stream,又没有 `TranscodingUrl`
    case noPlayablePath
    /// 本地拼 URL 失败(不是服务端的问题)
    case urlConstructionFailed
    /// 响应缺少构造播放所必需的字段(API_CONTRACT.md 8.1)
    case missingRequiredField(name: String)

    var userMessage: String {
        switch self {
        case .serverRejected(let code):
            return "服务器拒绝播放(错误码 \(code))。"
        case .noMediaSource:
            return "服务器没有返回任何可播放的媒体源。"
        case .noPlayablePath:
            return "这台服务器对该文件既不支持直接串流,也没有给出转码地址。"
        case .urlConstructionFailed:
            return "播放地址构造失败,请检查服务器地址设置。"
        case .missingRequiredField(let name):
            return "服务器返回的播放信息缺少必需字段 \(name)。"
        }
    }
}

/// 决策结论:**走哪条路 + 选中哪条源**。不含地址 —— 地址怎么拼是每个来源自己的事。
///
/// 拆出它是为了让**非 Emby 来源**也能用同一张判定表,而不必经过
/// `PlaybackURLBuilder`(那是 Emby 的地址规则,见 `PlaybackDecisionEngine.decision(for:)`)。
struct PlaybackDecision: Sendable, Equatable {
    let method: PlaybackMethod
    /// **被选中**的那条源(不是响应里的第一条)
    let source: EmbyMediaSource
    let playSessionID: String
}

/// 播放决策引擎(API_CONTRACT.md 4.4)。
///
/// **纯函数**:不持有状态、不做网络请求、不读本地凭据 —— 输入一份
/// `PlaybackInfo` 响应,输出一个 `PlaybackDecision`(或再拼成 `PlaybackSession`)。
/// 这样「仅转码可用」「无可播路径」这类分支可以完全用 fixture 覆盖,
/// 不需要真实服务器(API_CONTRACT.md 4.4)。
///
/// 分两层:
/// - `decision(for:)` —— 4.4 的第 1–3 步 + 走哪条路。**唯一判定入口**,
///   百度源也走它(把 `BaiduPanFile` 映射成一份响应形状喂进来);
/// - `session(for:itemID:urlBuilder:headers:)` —— 在决策之上按 Emby 的地址规则
///   拼出可播会话。
///
/// 算法严格照 4.4 的六步;唯一补充是第 2 步之后校验 `PlaySessionId`
/// —— 4.5 把它列为串流 URL 的必填参数,而官方 schema 并未保证它一定出现
/// (服务端拒绝播放时可能只给 `ErrorCode`),所以缺值时报
/// `missingRequiredField` 而不是让它悄悄变成空串。
enum PlaybackDecisionEngine {

    /// 判定「走哪条路、播哪条源」。⛔ 不碰地址。
    static func decision(for response: EmbyPlaybackInfoResponse) throws -> PlaybackDecision {
        // 1. ErrorCode 非空 → 服务端拒绝播放
        if let code = response.errorCode {
            throw PlaybackError.serverRejected(code: code)
        }

        // 2. MediaSources 为空(或缺失)→ 没有可播源
        guard let sources = response.mediaSources, !sources.isEmpty else {
            throw PlaybackError.noMediaSource
        }

        // 3. PlaySessionId:4.5 把它列为串流 URL 的必填参数,后续停止/上报
        //    也靠它。缺了不能靠猜,也不能拿空串顶替(8.1 禁止填假默认值)。
        guard let playSessionID = response.playSessionID, !playSessionID.isEmpty else {
            throw PlaybackError.missingRequiredField(name: "PlaySessionId")
        }

        // 4. 选定 MediaSource:多个时取第一个支持 DirectStream 的,
        //    都不支持则取第一个(4.4 第 3 步)
        let selected = sources.first { $0.supportsDirectStream == true } ?? sources[0]

        // 5. 支持 DirectStream → 直连
        if selected.supportsDirectStream == true {
            return PlaybackDecision(
                method: .directStream, source: selected, playSessionID: playSessionID)
        }

        // 6. 退到转码。空字符串与缺失同义:**没有**可用的转码地址,
        //    ⛔ 不让一个空地址往后走到拼 URL 那一步再报另一种错。
        guard let relative = selected.transcodingUrl, !relative.isEmpty else {
            throw PlaybackError.noPlayablePath
        }
        return PlaybackDecision(
            method: .transcode, source: selected, playSessionID: playSessionID)
    }

    /// 决策 + 按 Emby 的地址规则拼出可播会话。
    ///
    /// 失败来源:决策本身(`PlaybackError`)与本地拼 URL 失败
    /// (`urlConstructionFailed`,不是服务端的问题)。
    static func session(
        for response: EmbyPlaybackInfoResponse,
        itemID: String,
        urlBuilder: PlaybackURLBuilder,
        headers: [String: String]
    ) throws -> PlaybackSession {
        let decision = try decision(for: response)
        let selected = decision.source

        switch decision.method {
        case .directStream:
            // 优先用服务端给的 DirectStreamUrl(Emby Web 的做法);没有或解析不了才自拼
            guard let url = selected.directStreamUrl.flatMap({ urlBuilder.directStreamURL(serverProvided: $0) })
                ?? urlBuilder.directStreamURL(
                    itemID: itemID,
                    container: selected.container,
                    mediaSourceID: selected.id,
                    playSessionID: decision.playSessionID
                ) else {
                throw PlaybackError.urlConstructionFailed
            }
            return PlaybackSession(
                plan: .directStream(
                    url: url,
                    headers: headers,
                    playSessionID: decision.playSessionID,
                    mediaSourceID: selected.id
                ),
                mediaSource: selected,
                // 整份文件 → 交给内核 seek
                seekStrategy: .clientSeek
            )

        case .transcode:
            // `decision` 已保证 `transcodingUrl` 非空
            guard let relative = selected.transcodingUrl,
                  let url = urlBuilder.transcodeURL(relativePath: relative) else {
                throw PlaybackError.urlConstructionFailed
            }
            return PlaybackSession(
                plan: .transcode(
                    url: url,
                    headers: headers,
                    playSessionID: decision.playSessionID,
                    mediaSourceID: selected.id
                ),
                mediaSource: selected,
                // 转码流不能客户端 seek:必须停流 + StartTimeTicks 重新起流(4.5)
                seekStrategy: .restartStream
            )
        }
    }
}
