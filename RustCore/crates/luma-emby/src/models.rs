//! `POST /Items/{Id}/PlaybackInfo` 的请求体与响应体(`API_CONTRACT.md` 第 4.3 节)。
//!
//! 字段名一律**显式** `rename`,⛔ 不用 `rename_all` 之类的自动转换:
//! Emby 的键是 PascalCase,而 `DirectStreamUrl` / `PlaySessionId` 这种
//! 连写词没有统一规则,自动转换必然猜错。与 Swift 侧显式 `CodingKeys` 同源。
//!
//! 可选性照 `API_CONTRACT.md` 8.1:**只有 `MediaSource.Id` 必填**,其余全可选。
//! 不解的字段一律不留在结构体里 —— 避免出现「解了但没人读」的属性假装已支持。

use serde::{Deserialize, Serialize};

use crate::device_profile::DeviceProfile;

/// `POST /Items/{Id}/PlaybackInfo` 的请求体(官方 schema `MediaInfo.PlaybackInfoRequest`)。
///
/// ⛔ **刻意没有 `EnableDirectPlay` 字段**(`API_CONTRACT.md` 4.3):LumaPlayer 是纯 HTTP
/// 客户端,不读 `MediaSource.Path`,DirectPlay 开不开无所谓;而本地 4.9.5.0 实测过
/// 「带 `DeviceProfile` 时发 `EnableDirectPlay=false` 会把 `SupportsDirectStream`
/// 一起关成 false」。没有字段 = 不可能发错。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PlaybackInfoRequest {
    #[serde(rename = "UserId")]
    pub user_id: String,
    #[serde(rename = "EnableDirectStream")]
    pub enable_direct_stream: bool,
    #[serde(rename = "EnableTranscoding")]
    pub enable_transcoding: bool,
    /// 转码 seek 靠它重新起流(`API_CONTRACT.md` 4.5)。`None` 时**整键省略** ——
    /// 它是服务端决策的输入之一,发 `null` 等于多给一个无谓信号。
    #[serde(rename = "StartTimeTicks", skip_serializing_if = "Option::is_none")]
    pub start_time_ticks: Option<i64>,
    #[serde(rename = "DeviceProfile")]
    pub device_profile: DeviceProfile,
}

impl PlaybackInfoRequest {
    /// 起播请求:`EnableDirectStream` / `EnableTranscoding` 都是 true
    /// (DirectStream 优先、转码作降级),不带 `StartTimeTicks`。
    pub fn new(user_id: &str, device_profile: DeviceProfile) -> Self {
        Self {
            user_id: user_id.to_string(),
            enable_direct_stream: true,
            enable_transcoding: true,
            start_time_ticks: None,
            device_profile,
        }
    }

    /// 转码 seek:同一份请求 + `StartTimeTicks`(`API_CONTRACT.md` 4.5,
    /// 转码流不能客户端 seek,只能停流后用这个字段重新起一路)。
    pub fn at_position(mut self, ticks: i64) -> Self {
        self.start_time_ticks = Some(ticks);
        self
    }
}

/// `POST /Items/{Id}/PlaybackInfo` 的响应(官方 schema `MediaInfo.PlaybackInfoResponse`)。
///
/// 官方 schema 只有这三个字段,且**没有把任何一个标为 required**;
/// 服务端拒绝播放时(`ErrorCode` 非空)可能连 `PlaySessionId` 都不给。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct PlaybackInfoResponse {
    /// 可能缺失、可能是空数组 —— 两种都按「没有可播源」处理(决策器第 2 步)。
    #[serde(rename = "MediaSources", default)]
    pub media_sources: Option<Vec<MediaSource>>,
    #[serde(rename = "PlaySessionId", default)]
    pub play_session_id: Option<String>,
    /// 非空即服务端拒绝。官方枚举 `NotAllowed` / `NoCompatibleStream` /
    /// `RateLimitExceeded`,但按自由字符串解 —— 枚举外的值不该让解码失败。
    #[serde(rename = "ErrorCode", default)]
    pub error_code: Option<String>,
}

/// `PlaybackInfo` 返回的一个可播源(官方 schema `MediaSourceInfo`)。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MediaSource {
    /// 必填(`API_CONTRACT.md` 8.1)
    #[serde(rename = "Id")]
    pub id: String,
    /// `mkv` / `mp4` …。DirectStream 的输出格式 == 输入格式,故取这里的容器判「本机放不放得了」。
    #[serde(rename = "Container", default)]
    pub container: Option<String>,
    #[serde(rename = "SupportsDirectStream", default)]
    pub supports_direct_stream: Option<bool>,
    #[serde(rename = "SupportsTranscoding", default)]
    pub supports_transcoding: Option<bool>,
    /// 服务端给的直连地址(相对 API 根,带 `api_key`,取用时必须剥掉;4.5.1)。
    #[serde(rename = "DirectStreamUrl", default)]
    pub direct_stream_url: Option<String>,
    /// 服务端拼好的转码流地址(相对路径)。这是**唯一**合法的转码入口 ——
    /// 决策器⛔ 不自己拼(4.4 第 6 步)。
    #[serde(rename = "TranscodingUrl", default)]
    pub transcoding_url: Option<String>,
    /// `hls` / `http`,决定客户端用什么方式消费转码流。
    #[serde(rename = "TranscodingSubProtocol", default)]
    pub transcoding_sub_protocol: Option<String>,
    #[serde(rename = "MediaStreams", default)]
    pub media_streams: Option<Vec<MediaStream>>,
}

impl MediaSource {
    /// 该类型的轨道(`Video` / `Audio` / `Subtitle`);`MediaStreams` 缺失时返回空切片。
    ///
    /// 判定「用什么编码」「有没有位图字幕」都走它 —— 这些是**响应里的事实**,
    /// ⛔ 决策器不按文件扩展名或文件名猜(`ARCHITECTURE.md` 3.3)。
    pub fn streams_of(&self, stream_type: &str) -> Vec<&MediaStream> {
        self.media_streams
            .as_deref()
            .unwrap_or_default()
            .iter()
            .filter(|s| s.stream_type.as_deref() == Some(stream_type))
            .collect()
    }
}

/// 一条媒体轨(官方 schema `MediaStream`)。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MediaStream {
    #[serde(rename = "Index", default)]
    pub index: Option<i32>,
    /// `Video` / `Audio` / `Subtitle`。官方是自由字符串,不枚举。
    #[serde(rename = "Type", default)]
    pub stream_type: Option<String>,
    /// 编码名。视频 `h264` / `hevc`;音频 `aac` / `dts` / `truehd`;
    /// 字幕 `subrip` / `ass` / `hdmv_pgs_subtitle` …
    #[serde(rename = "Codec", default)]
    pub codec: Option<String>,
    #[serde(rename = "Language", default)]
    pub language: Option<String>,
    #[serde(rename = "IsDefault", default)]
    pub is_default: Option<bool>,
    /// 文本字幕才有的独立下载端点(`API_CONTRACT.md` 4.6)。
    /// 位图字幕这个字段是 false,且没有下载端点 → 只能烧录。
    #[serde(rename = "IsTextSubtitleStream", default)]
    pub is_text_subtitle_stream: Option<bool>,
    /// 外挂轨(不在容器里)
    #[serde(rename = "IsExternal", default)]
    pub is_external: Option<bool>,
    /// 服务端拼好的可读描述,如 `1080p HEVC`、`DTS 5.1`。只用于给人看的解释文案。
    #[serde(rename = "DisplayTitle", default)]
    pub display_title: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_never_carries_enable_direct_play() {
        let json = serde_json::to_string(
            &PlaybackInfoRequest::new("u1", DeviceProfile::avkit()),
        )
        .expect("序列化");

        assert!(
            !json.contains("EnableDirectPlay"),
            "⛔ 不允许出现 EnableDirectPlay(API_CONTRACT 4.3),实际:{json}"
        );
        assert!(json.contains("\"EnableDirectStream\":true"));
        assert!(json.contains("\"EnableTranscoding\":true"));
    }

    #[test]
    fn start_time_ticks_is_omitted_when_absent() {
        let json = serde_json::to_string(
            &PlaybackInfoRequest::new("u1", DeviceProfile::avkit()),
        )
        .expect("序列化");
        assert!(
            !json.contains("StartTimeTicks"),
            "起播请求不该带 StartTimeTicks(4.5),实际:{json}"
        );

        let seeked = serde_json::to_string(
            &PlaybackInfoRequest::new("u1", DeviceProfile::avkit()).at_position(12_345),
        )
        .expect("序列化");
        assert!(seeked.contains("\"StartTimeTicks\":12345"));
    }

    /// 官方 schema 没把任何字段标为 required;缺 `MediaSources` 只是
    /// `None`,不该解码失败。
    #[test]
    fn response_decodes_with_every_optional_field_absent() {
        let parsed: PlaybackInfoResponse =
            serde_json::from_str("{}").expect("空对象也要能解");
        assert_eq!(parsed.media_sources, None);
        assert_eq!(parsed.play_session_id, None);
        assert_eq!(parsed.error_code, None);
    }

    #[test]
    fn response_decodes_error_code_only() {
        let parsed: PlaybackInfoResponse =
            serde_json::from_str(r#"{"ErrorCode":"NoCompatibleStream"}"#).expect("解码");
        assert_eq!(parsed.error_code.as_deref(), Some("NoCompatibleStream"));
        assert_eq!(parsed.media_sources, None);
    }

    #[test]
    fn source_filters_streams_by_type() {
        let source: MediaSource = serde_json::from_str(
            r#"{
                "Id": "src-1",
                "MediaStreams": [
                    {"Index": 0, "Type": "Video", "Codec": "h264"},
                    {"Index": 1, "Type": "Audio", "Codec": "aac"},
                    {"Index": 2, "Type": "Subtitle", "Codec": "hdmv_pgs_subtitle"}
                ]
            }"#,
        )
        .expect("解码");

        assert_eq!(source.streams_of("Video").len(), 1);
        assert_eq!(source.streams_of("Audio").len(), 1);
        assert_eq!(source.streams_of("Subtitle").len(), 1);
        assert!(source.streams_of("Lyric").is_empty());
    }

    /// `MediaStreams` 整个字段缺失时不能 panic,也不能假装有轨。
    #[test]
    fn source_without_streams_yields_empty() {
        let source: MediaSource = serde_json::from_str(r#"{"Id":"src-1"}"#).expect("解码");
        assert_eq!(source.media_streams, None);
        assert!(source.streams_of("Video").is_empty());
    }
}
