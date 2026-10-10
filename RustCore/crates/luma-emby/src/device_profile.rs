//! `DeviceProfile` —— 请求体里那段「客户端能放什么」的声明。
//!
//! 这是 `avkit-rust-rearchitecture.md` 第 4 节的**阻塞项**:libmpv 时代只声明
//! 「容器/编码不限」(那时 mpv 什么都能放,写窄了反而白白浪费服务端 CPU);
//! 换成 AVKit 后局面反转 —— 声明写宽的后果不是浪费,是**静默失败**:
//! 服务端以为 DirectStream 可行,返回一个 AVKit 放不了的流,表现为黑屏或无声,
//! 而决策器不会报错。
//!
//! 所以本文件的 `Container` / `VideoCodec` / `AudioCodec` 白名单
//! **一律从 [`AvkitCapabilities`] 派生**,⛔ 不允许各写一份 ——
//! 两份白名单一旦漂移,「声明给服务端的」和「自己判定的」就会不一致,
//! 而那正是静默失败的温床。`direct_play_matches_capability_table` 测试守着这条。

use serde::Serialize;

use crate::capability::AvkitCapabilities;

/// 请求体里的 `DeviceProfile`(官方 schema `DeviceProfile`)。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DeviceProfile {
    #[serde(rename = "Name")]
    pub name: String,
    #[serde(rename = "DirectPlayProfiles")]
    pub direct_play_profiles: Vec<DirectPlayProfile>,
    #[serde(rename = "SubtitleProfiles")]
    pub subtitle_profiles: Vec<SubtitleProfile>,
    #[serde(rename = "TranscodingProfiles")]
    pub transcoding_profiles: Vec<TranscodingProfile>,
}

/// 服务端可以**原样**交给客户端的容器/编码组合。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DirectPlayProfile {
    /// 逗号分隔的容器白名单(Emby 的写法)
    #[serde(rename = "Container")]
    pub container: String,
    #[serde(rename = "Type")]
    pub profile_type: String,
    #[serde(rename = "VideoCodec")]
    pub video_codec: String,
    #[serde(rename = "AudioCodec")]
    pub audio_codec: String,
}

/// 字幕怎么交付。`Method` 是 Emby 的关键字段:
/// - `Embed`:留在容器里,客户端自己渲染
/// - `External`:服务端另给一条可下载的字幕流(客户端去取 `Stream.vtt`)
/// - `Encode`:烧进画面
///
/// ⛔ **位图字幕刻意不出现在本表里** —— 不声明就等于告诉服务端
/// 「这种字幕我没法自己显示」,由服务端决定烧录。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SubtitleProfile {
    #[serde(rename = "Format")]
    pub format: String,
    #[serde(rename = "Method")]
    pub method: String,
}

/// 服务端该把转码结果做成什么样。AVKit 这边选最稳的 mp4(h264/aac)。
///
/// ⚠️ 刻意不用 HLS:P2 只做决策,交付方式(progressive mp4 + `StartTimeTicks`
/// 重新起流,还是 HLS)是 P3 的实测题目。这里先声明 mp4/http,
/// 与既有 `API_CONTRACT.md` 4.5 的「转码 seek 靠重新起流」一致。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TranscodingProfile {
    #[serde(rename = "Container")]
    pub container: String,
    #[serde(rename = "Type")]
    pub profile_type: String,
    #[serde(rename = "VideoCodec")]
    pub video_codec: String,
    #[serde(rename = "AudioCodec")]
    pub audio_codec: String,
    #[serde(rename = "Protocol")]
    pub protocol: String,
    #[serde(rename = "Context")]
    pub context: String,
    #[serde(rename = "MaxAudioChannels")]
    pub max_audio_channels: String,
    #[serde(rename = "MinSegments")]
    pub min_segments: String,
    #[serde(rename = "BreakOnNonKeyFrames")]
    pub break_on_non_key_frames: bool,
}

impl DeviceProfile {
    /// 本分支(AVKit)该发的 profile:只声明 Apple 原生放得了的东西。
    pub fn avkit() -> Self {
        let caps = AvkitCapabilities::current();
        Self::from_capabilities(&caps)
    }

    /// 从能力表派生。两条白名单共用同一份常量,防止漂移。
    pub fn from_capabilities(caps: &AvkitCapabilities) -> Self {
        let subtitle_profiles = caps
            .native_subtitle_codecs
            .iter()
            // 系统能在容器里直读 → 留在容器里
            .map(|codec| SubtitleProfile {
                format: (*codec).to_string(),
                method: "Embed".to_string(),
            })
            .chain(caps.convertible_subtitle_codecs.iter().map(|codec| SubtitleProfile {
                format: (*codec).to_string(),
                // 服务端转成纯文本另发一条,客户端去下载(API_CONTRACT.md 4.6)
                method: "External".to_string(),
            }))
            .collect();

        Self {
            name: "LumaPlayer".to_string(),
            direct_play_profiles: vec![DirectPlayProfile {
                container: caps.native_containers.join(","),
                profile_type: "Video".to_string(),
                video_codec: caps.native_video_codecs.join(","),
                audio_codec: caps.native_audio_codecs.join(","),
            }],
            subtitle_profiles,
            transcoding_profiles: vec![TranscodingProfile {
                container: "mp4".to_string(),
                profile_type: "Video".to_string(),
                video_codec: "h264".to_string(),
                audio_codec: "aac".to_string(),
                protocol: "http".to_string(),
                context: "Streaming".to_string(),
                max_audio_channels: "2".to_string(),
                min_segments: "1".to_string(),
                break_on_non_key_frames: true,
            }],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_play_matches_capability_table() {
        let caps = AvkitCapabilities::current();
        let profile = DeviceProfile::from_capabilities(&caps);
        let direct = &profile.direct_play_profiles[0];

        for container in direct.container.split(',') {
            assert!(
                caps.native_containers.contains(&container),
                "DirectPlayProfile 声明了能力表里没有的容器 {container} —— 两份白名单已漂移"
            );
        }
        for codec in direct.video_codec.split(',') {
            assert!(
                caps.native_video_codecs.contains(&codec),
                "DirectPlayProfile 声明了能力表里没有的视频编码 {codec}"
            );
        }
        for codec in direct.audio_codec.split(',') {
            assert!(
                caps.native_audio_codecs.contains(&codec),
                "DirectPlayProfile 声明了能力表里没有的音频编码 {codec}"
            );
        }
    }

    /// 位图字幕绝不能出现在声明里 —— 声明了就等于告诉服务端
    /// 「给我原样的位图轨」,而客户端根本渲染不出来。
    #[test]
    fn bitmap_subtitles_are_never_declared() {
        let caps = AvkitCapabilities::current();
        let profile = DeviceProfile::from_capabilities(&caps);

        for sub in &profile.subtitle_profiles {
            assert!(
                !caps.bitmap_subtitle_codecs.contains(&sub.format.as_str()),
                "位图字幕 {} 不该出现在 SubtitleProfiles 里",
                sub.format
            );
        }
    }

    #[test]
    fn mkv_is_not_declared_as_direct_playable() {
        let profile = DeviceProfile::avkit();
        let containers = &profile.direct_play_profiles[0].container;
        assert!(
            !containers.split(',').any(|c| c == "mkv" || c == "webm"),
            "MKV/WebM 不是 AVKit 原生支持,不该出现在声明里:{containers}"
        );
    }

    #[test]
    fn serializes_with_pascal_case_keys() {
        let json = serde_json::to_value(DeviceProfile::avkit()).expect("序列化");
        assert!(json.get("DirectPlayProfiles").is_some());
        assert!(json.get("SubtitleProfiles").is_some());
        assert!(json.get("TranscodingProfiles").is_some());
        let first = &json["DirectPlayProfiles"][0];
        assert_eq!(first["Type"], "Video");
        assert!(first["Container"].as_str().unwrap().contains("mp4"));
    }
}
