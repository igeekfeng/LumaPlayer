import Foundation

/// 播放路径的判定结果(API_CONTRACT.md 4.2/4.5)。
///
/// ⛔ LumaPlayer **没有** `directPlay`:客户端访问不到服务端的文件系统,
/// 「用 HTTP 拉原始文件」在 Emby 语义里叫 Direct Stream。
/// 若将来支持本地挂载,再新增 `case directPlay(fileURL:)` —— 现在不预留。
///
/// ⚠️ `exp/avkit-rust-core`:本类型原先与 `PlaybackDecisionEngine` 同文件。
/// 决策搬去 Rust 后引擎删了,**但它是播放层的公共形状**(内核、上报、统计都用),
/// 所以单独留下 —— 与 `PlaybackTrack` 同一个理由。
enum PlaybackPlan: Sendable, Equatable {
    /// `static=true`:服务端原样吐原始文件,客户端可自由 seek
    case directStream(url: URL, headers: [String: String], playSessionID: String, mediaSourceID: String)
    /// 服务端转码。⚠️ 转码交付形态实测**只能是 HLS**(见
    /// `docs/DECISIONS/avkit-rust-rearchitecture.md` 8.5 实测一),所以这里的 URL 指向
    /// `master.m3u8`;seek 不是客户端 seek,而是停流 + `StartTimeTicks` 重新起流(4.5)。
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
///
/// `rawValue` 与 Rust 决策结果里的 `method` 是**同一套拼写**(`PlaybackPlanBuilder`
/// 靠它分派),不是巧合 —— 上报的 `PlayMethod` 也是这两个值。
///
/// ⛔ 这里**不再给中文显示名**:Rust 决策结果已经带了 `methodDisplayName`,
/// 两边各存一份的结果是「日志说 A,界面说 B」(定位见 luma_core.swift
/// `PlaybackFailureFfi` 的注释)。要显示名一律用 `PlaybackSession.decision`。
enum PlaybackMethod: String, Sendable, Equatable {
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

/// 播放层自己产生的失败(Swift 侧)。
///
/// ⚠️ 服务端与决策侧的失败**不在这里**:那些由 Rust 抛
/// `PlaybackFailureFfi`(带它自己生成的可读文案),内核侧的失败是
/// `PlaybackEngineFailure`。本类型只剩两件**本地**的事 —— 拼 URL 与 FFI 字符串漂移。
enum PlaybackError: Error, Equatable, Sendable {
    /// 本地拼 URL 失败(不是服务端的问题)
    case urlConstructionFailed
    /// Rust 决策给出的播放方式不是本分支认识的取值(`PlaybackPlanBuilder`)。
    /// 走到这里说明 FFI 两侧的字符串漂移了 —— 不是服务端的问题,如实报错。
    case unknownDecisionMethod(name: String)
    /// 决策选中的那条 `MediaSource` 在响应里找不到(解码口径不一致)。
    /// ⛔ 不退回「拿第一条凑数」:那会变成「播的是 A、判的是 B」。
    case mediaSourceNotFound(id: String)

    var userMessage: String {
        switch self {
        case .urlConstructionFailed:
            return "播放地址构造失败,请检查服务器地址设置。"
        case .unknownDecisionMethod(let name):
            return "播放决策给出了无法识别的播放方式(\(name))。"
        case .mediaSourceNotFound(let id):
            return "服务器返回的播放信息里找不到被选中的媒体源(\(id))。"
        }
    }
}
