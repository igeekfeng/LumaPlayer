import Foundation

/// `POST /Items/{Id}/PlaybackInfo` 的请求体
/// (MediaInfo.PlaybackInfoRequest,官方 OpenAPI 核实 2026-09-22)
///
/// ⚠️ **刻意省略 `DeviceProfile`**(API_CONTRACT.md 4.3):
/// 先观察服务端在不给 profile 时的默认行为,拿到真实响应后再决定要不要补
/// `DirectPlayProfiles`。⛔ 禁止凭想象写一个几百行的 DeviceProfile。
///
/// `MaxStreamingBitrate` / `AudioStreamIndex` / `SubtitleStreamIndex` 等字段
/// 官方 schema 里都有,但用不到就不发(8.1)。另外只发了
/// `StartTimeTicks`:转码 seek 必须靠它重新起流(4.5)。
struct PlaybackInfoRequest: Encodable, Sendable, Equatable {
    let userID: String
    /// **不发**(nil 时整个键省略;API_CONTRACT.md 4.3):LumaPlayer 是纯 HTTP 客户端,
    /// 不会去读 `Path`,引擎也只认 `SupportsDirectStream`,所以 DirectPlay 是否开启无所谓。
    /// 曾固定发 `false`,但本地 4.9.5.0 实测:带 `DeviceProfile` 时 `EnableDirectPlay=false`
    /// 会连 `SupportsDirectStream` 一起关掉(改走转码)。Emby Web 也不发这个键。
    let enableDirectPlay: Bool?
    let enableDirectStream: Bool
    /// 作为降级保留:DirectStream 不行时服务端可以给转码地址。
    let enableTranscoding: Bool
    /// 转码起流位置(4.5 的 `StartTimeTicks`)。nil 时**整个键省略** ——
    /// 它是服务端判断「要不要转码」的输入之一,DirectStream 路径发
    /// `StartTimeTicks: null` 等于无谓地多给一个信号。
    let startTimeTicks: Int64?
    /// 最小 `DeviceProfile`(Emby Web 与 OcPlayer 都会带)。不带的话服务端不给 `DirectStreamUrl`,
    /// 部分带网关的服务器在自拼串流地址时回 200 + JSON 错误体(issue #2)。
    let deviceProfile = DeviceProfile()

    /// 只声明「视频容器/编码不限」:libmpv 什么都能播,不需要服务端替我们挑。
    /// ⛔ 不要在这里写长长的容器/编码白名单 —— 写窄了服务端会把本来能直连的转码
    /// (API_CONTRACT.md 4.3)。本地 4.9.5.0 实测这个形态下 `SupportsDirectStream` 保持 true。
    struct DeviceProfile: Encodable, Sendable, Equatable {
        struct DirectPlayProfile: Encodable, Sendable, Equatable {
            let type = "Video"
            enum CodingKeys: String, CodingKey { case type = "Type" }
        }
        let directPlayProfiles = [DirectPlayProfile()]
        enum CodingKeys: String, CodingKey { case directPlayProfiles = "DirectPlayProfiles" }
    }

    init(
        userID: String,
        enableDirectPlay: Bool? = nil,
        enableDirectStream: Bool = true,
        enableTranscoding: Bool = true,
        startTimeTicks: Int64? = nil
    ) {
        self.userID = userID
        self.enableDirectPlay = enableDirectPlay
        self.enableDirectStream = enableDirectStream
        self.enableTranscoding = enableTranscoding
        self.startTimeTicks = startTimeTicks
    }

    /// 键名即 API_CONTRACT.md / 官方 schema 的拼写,禁止改写(8.2 用显式
    /// CodingKeys,不用自动转换策略)。
    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case enableDirectPlay = "EnableDirectPlay"
        case deviceProfile = "DeviceProfile"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case startTimeTicks = "StartTimeTicks"
    }

    /// ⛔ 不用合成的 `encode`:它把 nil 写成 `StartTimeTicks: null`,
    /// 服务端要不要因此改变决策无从判断(4.3 只说这个字段存在)。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encodeIfPresent(enableDirectPlay, forKey: .enableDirectPlay)
        try container.encode(enableDirectStream, forKey: .enableDirectStream)
        try container.encode(enableTranscoding, forKey: .enableTranscoding)
        try container.encodeIfPresent(startTimeTicks, forKey: .startTimeTicks)
        try container.encode(deviceProfile, forKey: .deviceProfile)
    }
}

/// `POST /Items/{Id}/PlaybackInfo` 的响应
/// (MediaInfo.PlaybackInfoResponse,官方 OpenAPI 核实 2026-09-22)
///
/// 官方 schema 只列了这三个字段,且**没有把任何字段标为 required**;
/// 服务端拒绝播放(`ErrorCode` 非空)时还可能连 `PlaySessionId` 都不给。
/// 因此 `PlaySessionId` 按可选解码,缺值由决策引擎报
/// `PlaybackError.missingRequiredField`(API_CONTRACT.md 8.1 已据此回填)。
struct EmbyPlaybackInfoResponse: Decodable, Sendable, Equatable {
    /// 可能为 nil 或空数组 —— 两种情况都按「没有可播源」处理。
    /// ⛔ 不填 `[]` 默认值(8.1:禁止为了让上层好写而造缺省值)。
    let mediaSources: [EmbyMediaSource]?
    let playSessionID: String?
    /// 非空即服务端拒绝播放。官方枚举:`NotAllowed` /
    /// `NoCompatibleStream` / `RateLimitExceeded`;这里按普通字符串解,
    /// 服务端给了枚举外的值也不会解码失败。
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}
