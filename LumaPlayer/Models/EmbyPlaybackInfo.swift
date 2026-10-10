import Foundation

/// `POST /Items/{Id}/PlaybackInfo` 的请求体
/// (MediaInfo.PlaybackInfoRequest,官方 OpenAPI 核实 2026-09-22)
///
/// ## `DeviceProfile` 是 Rust 那份,原样发出去
///
/// `exp/avkit-rust-core` 第 4 节的**前置阻塞**就在这一段:声明写宽会让服务端把
/// MKV / DTS / PGS 全判成「可以直接串流」且**不给转码地址**,AVKit 拿到就是黑屏
/// 或无声(P2 本机实测,文档 8.2)。所以：
///
/// - 白名单**只有 Rust 一份** (`luma-emby::device_profile`,从能力表派生);
/// - 本类型通过 `deviceProfileJSON` 收到它,**逐字**写进请求体。
///
/// ⛔ 不要把 `DeviceProfile` 重新建模成 Swift 结构体再编码:那等于把白名单
/// 在 Swift 里再抄一份,而两份白名单漂移正是静默失败的温床。
///
/// ## 请求体为什么不是 `Encodable`
///
/// 不是省事,是因为「原样嵌入一段 JSON」用 `Encodable` 表达不出来 —— 要么为它写一个
/// 通用 JSON 值类型,要么在 `JSONSerialization` 的字典里嵌套。这里取后者:
/// 请求体一共 5 个键,多一层类型只会多一处可以写错的地方。
struct PlaybackInfoRequest: Sendable, Equatable {
    let userID: String
    /// **不发**(API_CONTRACT.md 4.3):LumaPlayer 是纯 HTTP 客户端,不会去读 `Path`,
    /// 引擎也只认 `SupportsDirectStream`,所以 DirectPlay 是否开启无所谓。
    /// 曾固定发 `false`,但本地 4.9.5.0 实测:带 `DeviceProfile` 时 `EnableDirectPlay=false`
    /// 会连 `SupportsDirectStream` 一起关掉(改走转码)。Emby Web 也不发这个键。
    let enableDirectStream: Bool
    /// 作为降级保留:DirectStream 不行时服务端可以给转码地址。
    let enableTranscoding: Bool
    /// 转码起流位置(4.5 的 `StartTimeTicks`)。nil 时**整个键省略** ——
    /// 它是服务端判断「要不要转码」的输入之一,DirectStream 路径发
    /// `StartTimeTicks: null` 等于无谓地多给一个信号。
    let startTimeTicks: Int64?
    /// Rust 派生的整份 `DeviceProfile` JSON
    let deviceProfileJSON: String

    init(
        userID: String,
        deviceProfileJSON: String,
        enableDirectStream: Bool = true,
        enableTranscoding: Bool = true,
        startTimeTicks: Int64? = nil
    ) {
        self.userID = userID
        self.deviceProfileJSON = deviceProfileJSON
        self.enableDirectStream = enableDirectStream
        self.enableTranscoding = enableTranscoding
        self.startTimeTicks = startTimeTicks
    }

    /// 键名即 API_CONTRACT.md / 官方 schema 的拼写,禁止改写。
    enum Key {
        static let userID = "UserId"
        static let enableDirectStream = "EnableDirectStream"
        static let enableTranscoding = "EnableTranscoding"
        static let startTimeTicks = "StartTimeTicks"
        static let deviceProfile = "DeviceProfile"
    }

    /// 请求体字节。
    ///
    /// - Throws: `DeviceProfile` 那段 JSON 解析不了时抛 `EncodingError`。
    ///   ⛔ 不退回「发一个空 profile」:那会静默改变服务端决策。
    func bodyData() throws -> Data {
        let profile = try JSONSerialization.jsonObject(
            with: Data(deviceProfileJSON.utf8), options: [.fragmentsAllowed])
        var body: [String: Any] = [
            Key.userID: userID,
            Key.enableDirectStream: enableDirectStream,
            Key.enableTranscoding: enableTranscoding,
            Key.deviceProfile: profile,
        ]
        // ⛔ 不给 `StartTimeTicks` 填 null:见属性注释
        if let startTimeTicks { body[Key.startTimeTicks] = startTimeTicks }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

/// `POST /Items/{Id}/PlaybackInfo` 的响应
/// (MediaInfo.PlaybackInfoResponse,官方 OpenAPI 核实 2026-09-22)
///
/// ⚠️ 本类型在 `exp/avkit-rust-core` 上**只用来取「被选中那条源」的轨道信息**
/// (起播后核轨用)。播放路径的判定已交给 Rust,它吃的是这份响应的**原始 JSON**
/// (`decidePlayback(playbackInfoJson:)`)—— 见 `PlaybackSessionCoordinator`。
///
/// 官方 schema 只列了这三个字段,且**没有把任何字段标为 required**;
/// 服务端拒绝播放(`ErrorCode` 非空)时还可能连 `PlaySessionId` 都不给。
/// 这些情况由 Rust 侧报错(文案在 `PlaybackFailureFfi` 里),Swift 不再重复判一遍。
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
