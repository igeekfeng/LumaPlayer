import Foundation

/// `PlaybackInfo` 返回的可播源(MediaSourceInfo,API_CONTRACT.md 4.3)。
/// 只有 `Id` 必填(8.1);只解真正要用的字段,不用的(`Path` …)不解。
struct EmbyMediaSource: Decodable, Sendable, Equatable {
    let id: String
    /// 多版本时服务端给每个版本起的名字(如 `Movie - 1080p`),可空。版本选择菜单的标签用它。
    var name: String? = nil
    /// DirectStream URL 的扩展名取这里(输出 == 输入,4.5)
    let container: String?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    /// 相对路径,需拼到站点根上(4.4 第 5 步)
    let transcodingUrl: String?
    /// 字节。弹幕匹配的 `fileSize` 与 `DanmakuFingerprint` 校验 `Content-Range` 总长用。
    var size: Int64? = nil
    /// bps。播放内核的缓冲预算按它标定(`MPVCacheBudget`);百度 / 本地合成源没有 → nil,预算走下限。
    var bitrate: Int64? = nil
    let mediaStreams: [EmbyMediaStream]?
    /// 章节与片头片尾标记(4.3.1)。取源上的而不是 Item 上的:多版本源的片头位置可以不同。
    /// `var` + 默认值只为让逐成员构造器可省略它。
    var chapters: [EmbyChapter]? = nil
    /// 形如 `/videos/{id}/original.mkv?...&api_key=..`,相对 API 根(不含 `/emby`,API_CONTRACT.md 4.5.1)。
    /// 带 `api_key`,取用时必须剥掉(认证走请求头)。
    var directStreamUrl: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
        case size = "Size"
        case bitrate = "Bitrate"
        case mediaStreams = "MediaStreams"
        case chapters = "Chapters"
    }
}

/// 一条媒体轨。`DisplayTitle` / 分辨率 / 声道只给详情页「媒体信息」用(API_CONTRACT.md 3.4)。
struct EmbyMediaStream: Decodable, Sendable, Equatable {
    let index: Int?
    /// `Video` / `Audio` / `Subtitle`(自由字符串,不枚举)
    let type: String?
    let codec: String?
    let language: String?
    let isDefault: Bool?
    /// 只有文本字幕才有独立下载端点(4.6)
    let isTextSubtitleStream: Bool?
    /// 不在容器里
    let isExternal: Bool?
    /// 如 `720p H264`、`AAC stereo (默认)`
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
    /// `MediaStreams` 缺失时返回 nil(不填 0)。
    func streamCount(of type: String) -> Int? {
        guard let streams = mediaStreams else { return nil }
        return streams.filter { $0.type == type }.count
    }
}

extension EmbyMediaSource {
    /// 版本菜单的标签:`{Name} · 1080p H264 · 8.2 GB`。服务端没给的部分直接省,全没有时退回容器名或 Id。
    var versionLabel: String {
        let video = mediaStreams?.first { $0.type == "Video" }
        let spec = video?.displayTitle
            ?? [video?.height.map { "\($0)p" }, video?.codec?.uppercased()].compactMap { $0 }.joined(separator: " ")
        let sizeText = size.map { $0.formatted(.byteCount(style: .file)) }
        let parts = [name, spec.isEmpty ? nil : spec, sizeText].compactMap { $0 }
        return parts.isEmpty ? (container?.uppercased() ?? id) : parts.joined(separator: " · ")
    }
}
