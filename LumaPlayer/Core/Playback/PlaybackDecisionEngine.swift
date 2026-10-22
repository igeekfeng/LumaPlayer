import Foundation

/// 播放路径(API_CONTRACT.md 4.2/4.5)。
///
/// ⛔ 没有 `directPlay`:客户端读不到服务端文件系统,HTTP 拉原始文件在 Emby 里叫 Direct Stream。
enum PlaybackPlan: Sendable, Equatable {
    /// `static=true`:原样吐原始文件,客户端可自由 seek
    case directStream(url: URL, headers: [String: String], playSessionID: String, mediaSourceID: String)
    /// 地址来自 `MediaSource.TranscodingUrl`。⛔ 不能用 mpv seek:停流 + `StartTimeTicks` 重新起流(4.5)
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

    var displayName: String {
        switch self {
        case .directStream: return "直接串流"
        case .transcode: return "服务端转码"
        }
    }
}

/// 播放决策失败的原因(都要给出可解释的文案)。
enum PlaybackError: Error, Equatable, Sendable {
    /// 响应里 `ErrorCode` 非空
    case serverRejected(code: String)
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

/// 决策结论:走哪条路 + 选中哪条源。不含地址(地址规则各来源自己定),
/// 非 Emby 来源因此也能复用同一张判定表。
struct PlaybackDecision: Sendable, Equatable {
    let method: PlaybackMethod
    /// 被选中的那条源(不一定是响应里的第一条)
    let source: EmbyMediaSource
    let playSessionID: String
}

/// 播放决策引擎(API_CONTRACT.md 4.4)。纯函数,分支全靠 fixture 覆盖。
///
/// - `decision(for:)`:唯一判定入口,百度源也走它(`BaiduPanFile` 映射成响应形状喂进来);
/// - `session(for:itemID:urlBuilder:headers:)`:在决策之上按 Emby 地址规则拼出会话。
///
/// 照 4.4 的步骤,额外校验 `PlaySessionId`:4.5 要求它必填,但 schema 不保证出现。
enum PlaybackDecisionEngine {

    /// ⛔ 不碰地址。
    static func decision(for response: EmbyPlaybackInfoResponse) throws -> PlaybackDecision {
        if let code = response.errorCode {
            throw PlaybackError.serverRejected(code: code)
        }

        guard let sources = response.mediaSources, !sources.isEmpty else {
            throw PlaybackError.noMediaSource
        }

        // 停止 / 上报也靠它;⛔ 不拿空串顶替(8.1)
        guard let playSessionID = response.playSessionID, !playSessionID.isEmpty else {
            throw PlaybackError.missingRequiredField(name: "PlaySessionId")
        }

        // 取第一个支持 DirectStream 的,都不支持则取第一个(4.4 第 3 步)
        let selected = sources.first { $0.supportsDirectStream == true } ?? sources[0]

        if selected.supportsDirectStream == true {
            return PlaybackDecision(
                method: .directStream, source: selected, playSessionID: playSessionID)
        }

        // 空串与缺失同义
        guard let relative = selected.transcodingUrl, !relative.isEmpty else {
            throw PlaybackError.noPlayablePath
        }
        return PlaybackDecision(
            method: .transcode, source: selected, playSessionID: playSessionID)
    }

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
                seekStrategy: .restartStream
            )
        }
    }
}
