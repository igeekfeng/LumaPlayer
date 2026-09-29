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

/// 播放决策引擎(API_CONTRACT.md 4.4)。
///
/// **纯函数**:不持有状态、不做网络请求、不读本地凭据 —— 输入一份
/// `PlaybackInfo` 响应,输出一个 `PlaybackPlan` 或抛错。这样「仅转码可用」
/// 「无可播路径」这类分支可以完全用 fixture 覆盖,不需要真实服务器
/// (ARCHITECTURE.md 6.4)。
///
/// 算法严格照 4.4 的六步;唯一补充是第 2 步之后校验 `PlaySessionId`
/// —— 4.5 把它列为串流 URL 的必填参数,而官方 schema 并未保证它一定出现
/// (服务端拒绝播放时可能只给 `ErrorCode`),所以缺值时报
/// `missingRequiredField` 而不是让它悄悄变成空串。
enum PlaybackDecisionEngine {
    static func session(
        for response: EmbyPlaybackInfoResponse,
        itemID: String,
        urlBuilder: PlaybackURLBuilder,
        headers: [String: String]
    ) throws -> PlaybackSession {
        // 1. ErrorCode 非空 → 服务端拒绝播放
        if let code = response.errorCode {
            throw PlaybackError.serverRejected(code: code)
        }

        // 2. MediaSources 为空(或缺失)→ 没有可播源
        guard let sources = response.mediaSources, !sources.isEmpty else {
            throw PlaybackError.noMediaSource
        }

        // 2b. PlaySessionId:4.5 把列为串流 URL 的必填参数,后续停止/上报
        //     也靠它。缺了不能靠猜,也不能拿空串顶替(8.1 禁止填假默认值)。
        guard let playSessionID = response.playSessionID, !playSessionID.isEmpty else {
            throw PlaybackError.missingRequiredField(name: "PlaySessionId")
        }

        // 3. 选定 MediaSource:多个时取第一个支持 DirectStream 的,
        //    都不支持则取第一个(4.4 第 3 步)
        let selected = sources.first { $0.supportsDirectStream == true } ?? sources[0]

        // 4. 支持 DirectStream → static=true 原样拉流
        if selected.supportsDirectStream == true {
            // 优先用服务端给的 DirectStreamUrl(Emby Web 的做法);没有或解析不了才自拼
            guard let url = selected.directStreamUrl.flatMap({ urlBuilder.directStreamURL(serverProvided: $0) })
                ?? urlBuilder.directStreamURL(
                    itemID: itemID,
                    container: selected.container,
                    mediaSourceID: selected.id,
                    playSessionID: playSessionID
                ) else {
                throw PlaybackError.urlConstructionFailed
            }
            return PlaybackSession(
                plan: .directStream(
                    url: url,
                    headers: headers,
                    playSessionID: playSessionID,
                    mediaSourceID: selected.id
                ),
                mediaSource: selected
            )
        }

        // 5. 退到转码
        if let relative = selected.transcodingUrl,
           let url = urlBuilder.transcodeURL(relativePath: relative) {
            return PlaybackSession(
                plan: .transcode(
                    url: url,
                    headers: headers,
                    playSessionID: playSessionID,
                    mediaSourceID: selected.id
                ),
                mediaSource: selected
            )
        }

        // 6. 都没有 → 报错。⛔ 不得自己拼一个「猜的」URL 去试。
        throw PlaybackError.noPlayablePath
    }
}
