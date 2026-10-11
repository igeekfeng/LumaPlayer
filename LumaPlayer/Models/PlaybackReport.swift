import Foundation

/// `POST /Sessions/Playing*` 三个上报端点共用的请求体
/// (API_CONTRACT.md 5.1,来源官方 Playback-Check-ins.html)。
///
/// 三个端点 body **结构完全相同**,只有 Progress 多一个 `EventName` ——
/// 这里用可选字段表达:`eventName` 仅在 Progress 请求里非 nil,
/// 其余端点编码时省略(`encodeIfPresent`)。
///
/// 不使用的字段(`LiveStreamId` / `PlaylistIndex` / `PlaylistLength`)按 5.1 的
/// 「不使用」标注直接不建模,而不是发 null。
/// `SubtitleOffset` 同样不建模,但原因不同:字幕延迟功能已有,只是官方没写这个字段的
/// **单位**(KNOWN_ISSUES.md Q39)—— 发错单位比不发更糟,核实后再补。
struct PlaybackReportBody: Encodable, Sendable, Equatable {
    let itemID: String
    let mediaSourceID: String
    let playSessionID: String
    /// `DirectStream` / `Transcode`(`PlaybackMethod` 的 rawValue 与
    /// 5.1 的合法值一致,不是巧合 —— 4.2 定义的取值集合相同)
    let playMethod: String
    let positionTicks: Int64?
    let isPaused: Bool
    let isMuted: Bool
    /// 0–100
    let volumeLevel: Int?
    /// DirectStream 为 true;Transcode 为 false(4.5:转码流不能自由 seek)
    let canSeek: Bool
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    /// 固定 `["Video"]`(5.1)
    let queueableMediaTypes: [String]
    /// 仅 Progress 请求携带;其他端点省略
    let eventName: String?
    /// 当前倍速;nil 时编码省略
    let playbackRate: Double?

    init(
        itemID: String,
        mediaSourceID: String,
        playSessionID: String,
        playMethod: String,
        positionTicks: Int64?,
        isPaused: Bool,
        isMuted: Bool,
        volumeLevel: Int?,
        canSeek: Bool,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
        playbackRate: Double? = nil,
        eventName: String? = nil
    ) {
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.playMethod = playMethod
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.isMuted = isMuted
        self.volumeLevel = volumeLevel
        self.canSeek = canSeek
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.queueableMediaTypes = ["Video"]
        self.playbackRate = playbackRate
        self.eventName = eventName
    }

    /// ⛔ 不用合成的 `encode`:它把 nil 写成 `null`
    /// (`"SubtitleStreamIndex": null`),而 5.1 里这些字段是「有值才给」。
    /// 关字幕时**不发**这个键才是准确的表达(发 0 会指向第一条字幕轨)。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(mediaSourceID, forKey: .mediaSourceID)
        try container.encode(playSessionID, forKey: .playSessionID)
        try container.encode(playMethod, forKey: .playMethod)
        try container.encodeIfPresent(positionTicks, forKey: .positionTicks)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encodeIfPresent(volumeLevel, forKey: .volumeLevel)
        try container.encode(canSeek, forKey: .canSeek)
        try container.encodeIfPresent(audioStreamIndex, forKey: .audioStreamIndex)
        try container.encodeIfPresent(subtitleStreamIndex, forKey: .subtitleStreamIndex)
        try container.encode(queueableMediaTypes, forKey: .queueableMediaTypes)
        try container.encodeIfPresent(eventName, forKey: .eventName)
        try container.encodeIfPresent(playbackRate, forKey: .playbackRate)
    }

    /// 键名即官方文档拼写,禁止改写(8.2:显式 CodingKeys,不用自动策略)
    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case playMethod = "PlayMethod"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case volumeLevel = "VolumeLevel"
        case canSeek = "CanSeek"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case queueableMediaTypes = "QueueableMediaTypes"
        case eventName = "EventName"
        case playbackRate = "PlaybackRate"
    }
}

/// Progress 上报的事件名(API_CONTRACT.md 5.2)。
///
/// 只建模 LumaPlayer 实际会用到的映射;官方全集里的
/// `RepeatModeChange` / `PlaylistItem*` / `QualityChange` 等
/// 用不到,不先建(用不到的不解/不建,同 8.1 精神)。
enum PlaybackEventName: String, Sendable, Equatable {
    case timeUpdate = "TimeUpdate"
    case pause = "Pause"
    case unpause = "Unpause"
    case volumeChange = "VolumeChange"
    case audioTrackChange = "AudioTrackChange"
    case subtitleTrackChange = "SubtitleTrackChange"
    case playbackRateChange = "PlaybackRateChange"
}
