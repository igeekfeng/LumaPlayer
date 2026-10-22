import Foundation

/// `POST /Items/{Id}/PlaybackInfo` 的请求体(API_CONTRACT.md 4.3)。用不到的字段不发(8.1);
/// `StartTimeTicks` 是转码 seek 重新起流用的(4.5)。⛔ 不凭想象写完整的 DeviceProfile。
struct PlaybackInfoRequest: Encodable, Sendable, Equatable {
    let userID: String
    /// 默认不发(nil 时省略键,API_CONTRACT.md 4.3;Emby Web 也不发)。⛔ 不发 `false`:带 `DeviceProfile` 时
    /// 它会连 `SupportsDirectStream` 一起关掉(本地 4.9.5.0 实测)。引擎只认 `SupportsDirectStream`。
    let enableDirectPlay: Bool?
    let enableDirectStream: Bool
    /// DirectStream 不行时服务端可以给转码地址。
    let enableTranscoding: Bool
    /// 转码起流位置(4.5)。nil 时省略键:它是服务端判断要不要转码的输入之一。
    let startTimeTicks: Int64?
    /// 最小 `DeviceProfile`。不带服务端不给 `DirectStreamUrl`,部分带网关的服务器对自拼地址回 200 + JSON 错误体(issue #2)。
    let deviceProfile = DeviceProfile()

    /// 只声明「视频容器 / 编码不限」(libmpv 什么都能播)。⛔ 不写容器 / 编码白名单:写窄了能直连的会被转码
    /// (API_CONTRACT.md 4.3)。
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

    /// 键名即官方拼写,禁止改写(8.2 用显式 CodingKeys)。
    enum CodingKeys: String, CodingKey {
        case userID = "UserId"
        case enableDirectPlay = "EnableDirectPlay"
        case deviceProfile = "DeviceProfile"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case startTimeTicks = "StartTimeTicks"
    }

    /// ⛔ 不用合成的 `encode`:它会把 nil 写成 `null`。
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

/// `POST /Items/{Id}/PlaybackInfo` 的响应。官方没有 required 字段,拒绝播放时可能连 `PlaySessionId` 都不给;
/// 缺值由决策引擎报 `PlaybackError.missingRequiredField`(API_CONTRACT.md 8.1)。
struct EmbyPlaybackInfoResponse: Decodable, Sendable, Equatable {
    /// nil 与空数组都按「没有可播源」处理。⛔ 不填 `[]` 默认值(8.1)。
    let mediaSources: [EmbyMediaSource]?
    let playSessionID: String?
    /// 非空即拒绝播放(`NotAllowed` / `NoCompatibleStream` / `RateLimitExceeded`);按字符串解,枚举外的值不致解码失败。
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}
