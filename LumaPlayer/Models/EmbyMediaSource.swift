import Foundation

/// `PlaybackInfo` 返回的一个可播源(MediaSourceInfo,API_CONTRACT.md 4.3)。
///
/// 字段名来源:2026-09-22 对官方 OpenAPI(swagger.emby.media,Emby Server API
/// 4.1.1.0)`MediaSourceInfo` / `MediaStream` 的核实,
/// 见 API_CONTRACT.md 4.3。
///
/// 可选性按 `API_CONTRACT.md` 8.1:**只有 `Id` 必填**,其余一律可选。
/// 这里只解真正要用的字段 —— 不用的字段(`Path` / `Bitrate` / `RunTimeTicks` /
/// `LocationType` / `VideoType` …)一律不解,避免留下一堆没人读的属性假装“已支持”。
/// `Size` 例外:弹幕指纹要用它校验 Range 响应(`DanmakuFingerprint`)。
struct EmbyMediaSource: Decodable, Sendable, Equatable {
    /// 必填(API_CONTRACT.md 8.1)
    let id: String
    /// `mkv` / `mp4` …。DirectStream 的 URL 要带输出格式的扩展名,
    /// 而 DirectStream 的输出 == 输入,故取这里的 Container(4.5)。
    let container: String?
    /// 服务端是否愿意原样吐流(不转码、不重封装)
    let supportsDirectStream: Bool?
    /// 服务端是否支持转码
    let supportsTranscoding: Bool?
    /// 相对路径的转码流地址;需拼到站点根上(4.4 第 5 步)
    let transcodingUrl: String?
    /// 源文件大小(字节,`MediaSourceInfo.Size`,官方 OpenAPI 4.1.1.0 ✅ `int64` 可空)。
    ///
    /// 弹幕匹配用:弹弹play 的 `fileSize` 是 hash 之外的辅助判据,给得对能减少误配;
    /// 同时 `DanmakuFingerprint` 用它校验 `Content-Range` 的总长。缺失即 nil。
    var size: Int64? = nil
    /// 音视频与字幕轨
    let mediaStreams: [EmbyMediaStream]?
    /// 章节与片头片尾标记(4.3.1)。取源上的而不是外层 Item 上的:
    /// 与「时长用 MediaSource 的」同理,多版本源的片头位置可以不同。
    /// `var` + 默认值只为让逐成员构造器可以省略它(测试里手搓源时不必逐个补 nil);
    /// 合成的 Decodable 对带默认值的 `var` 照样按键解码。
    var chapters: [EmbyChapter]? = nil
    /// 服务端给的直连地址,形如 `/videos/{id}/original.mkv?DeviceId=..&MediaSourceId=..&PlaySessionId=..&api_key=..`。
    /// **相对 API 根**(不含 `/emby`;Emby Web 4.9.5.0 抓包核实,API_CONTRACT.md 4.5.1)。
    /// 带 `api_key`,取用时必须剥掉(认证走请求头)。
    var directStreamUrl: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
        case size = "Size"
        case mediaStreams = "MediaStreams"
        case chapters = "Chapters"
    }
}

/// 一条媒体轨(MediaStream)。
///
/// 播放只用得到轨道的基本描述与 4.6 判断“能否单独下载字幕”的两个标志;
/// `DisplayTitle` / 分辨率 / 声道是详情页「媒体信息」用的
/// (官方 OpenAPI 4.1.1.0 核实 2026-09-23,API_CONTRACT.md 3.4)。
struct EmbyMediaStream: Decodable, Sendable, Equatable {
    let index: Int?
    /// `Video` / `Audio` / `Subtitle`(官方 OpenAPI 里是自由字符串,不枚举)
    let type: String?
    let codec: String?
    let language: String?
    let isDefault: Bool?
    /// 文本字幕(`srt` / `srt` 类)。只有文本字幕才有独立下载端点(4.6)。
    let isTextSubtitleStream: Bool?
    /// 外挂轨道(不在容器里)
    let isExternal: Bool?
    /// 服务端拼好的可读描述,如 `720p H264`、`AAC stereo (默认)`
    let displayTitle: String?
    let title: String?
    let width: Int?
    let height: Int?
    let channels: Int?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case isDefault = "IsDefault"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case isExternal = "IsExternal"
        case displayTitle = "DisplayTitle"
        case title = "Title"
        case width = "Width"
        case height = "Height"
        case channels = "Channels"
    }
}

extension EmbyMediaSource {
    /// 该类型的轨道条数;`MediaStreams` 缺失时返回 nil(不填 0 假装没有)。
    func streamCount(of type: String) -> Int? {
        guard let streams = mediaStreams else { return nil }
        return streams.filter { $0.type == type }.count
    }
}
