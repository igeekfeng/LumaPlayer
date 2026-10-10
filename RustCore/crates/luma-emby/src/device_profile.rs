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

/// 服务端该把转码结果做成什么样。AVKit 这边选 HLS + MPEG-TS 段(h264/aac)。
///
/// ⭐ **HLS 不是偏好,是实测出来的唯一可行形态**(2026-10-10,P3)。
/// P2 曾刻意先声明 progressive mp4/http,把"交付形态"留给 P3 实测。实测结论是:
///
/// - 声明 `Protocol: "http"` 时服务端给 `stream.mp4`,响应头是
///   `Accept-Ranges: none` + `Transfer-Encoding: chunked`(**没有 Content-Length**)——
///   AVFoundation 认为服务器配置不对,`AVPlayerItem` 直接失败:
///   `AVFoundationErrorDomain -11850`(`AVErrorServerIncorrectlyConfigured`,SDK 头
///   `AVError.h:89`)。四个转码样本全军覆没,`Scripts/verify-avkit-playback.sh` 可复现。
/// - 声明 `Protocol: "hls"` 时服务端给 `master.m3u8` + `TranscodingSubProtocol=hls`,
///   AVPlayer 原生走 HLS 栈,同样的样本全部能起播。
///
/// ⛔ 所以声明里**只有 HLS 这一条**:两条并存时服务端挑哪条不受控,
/// 挑中 progressive 就等于整片放不了。
/// 容器取 `ts`:转码目标视频编码是 h264/aac(Apple 的传统 HLS 组合),
/// 不走 `forbidden_container_video_pairs` 那条例外(那条只约束直放声明)。
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

        // ⭐ 一条 `DirectPlayProfile` 里的 `Container × VideoCodec` 是**合取**关系,
        //    所以不能把所有容器和所有编码并成一条。「TS 能装 H.264 却不能装 HEVC」
        //    (P3 本机实测)这种例外必须拆成两条声明 —— 否则等于告诉服务端
        //    「HEVC 的 TS 直接给我吧」,而客户端拿到的是**没有画面的流**:
        //    `AVPlayerItem` 照样 readyToPlay、时间照走、`errorLog` 为空。
        //
        //    分组方式是从能力表推的(按「该容器允许的视频编码集合」归并),
        //    ⛔ 不手写死哪几条 —— 表里加一条例外,这里跟着变。
        let mut groups: Vec<(Vec<&'static str>, Vec<&'static str>)> = Vec::new();
        for container in caps.native_containers {
            let codecs = caps.native_video_codecs_for(container);
            match groups.iter_mut().find(|(_, existing)| *existing == codecs) {
                Some((containers, _)) => containers.push(container),
                None => groups.push((vec![container], codecs)),
            }
        }
        let direct_play_profiles = groups
            .into_iter()
            .map(|(containers, video_codecs)| DirectPlayProfile {
                container: containers.join(","),
                profile_type: "Video".to_string(),
                video_codec: video_codecs.join(","),
                audio_codec: caps.native_audio_codecs.join(","),
            })
            .collect();

        Self {
            name: "LumaPlayer".to_string(),
            direct_play_profiles,
            subtitle_profiles,
            transcoding_profiles: vec![TranscodingProfile {
                container: "ts".to_string(),
                profile_type: "Video".to_string(),
                video_codec: "h264".to_string(),
                audio_codec: "aac".to_string(),
                protocol: "hls".to_string(),
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

        for direct in &profile.direct_play_profiles {
            for container in direct.container.split(',') {
                assert!(
                    caps.native_containers.contains(&container),
                    "DirectPlayProfile 声明了能力表里没有的容器 {container} —— 两份白名单已漂移"
                );
                // ⭐ 声明的「容器 × 视频编码」组合,一条都不许是实测出来的例外组合。
                for codec in direct.video_codec.split(',') {
                    assert!(
                        !caps.is_forbidden_pair(container, codec),
                        "DirectPlayProfile 把实测放不了的组合 {container} × {codec} 声明成了可直放"
                    );
                }
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
    }

    /// ⭐ P3 实测带出来的性质:HEVC 的容器声明里**不能**出现 TS 家族。
    /// 这不是「少声明一点更保险」,而是「声明了就静默丢画面」。
    #[test]
    fn hevc_is_never_declared_direct_playable_in_the_ts_family() {
        let caps = AvkitCapabilities::current();
        let profile = DeviceProfile::from_capabilities(&caps);

        for direct in &profile.direct_play_profiles {
            let containers: Vec<&str> = direct.container.split(',').collect();
            let video_codecs: Vec<&str> = direct.video_codec.split(',').collect();
            if video_codecs.contains(&"hevc") {
                for ts in ["ts", "m2ts", "mts", "mpegts"] {
                    assert!(
                        !containers.contains(&ts),
                        "HEVC 与 {ts} 出现在同一条 DirectPlayProfile 里:{direct:?}"
                    );
                }
            }
        }
        // 反过来也要成立:TS 家族的 H.264 仍然要留在直放白名单里(实测通过)
        assert!(
            profile.direct_play_profiles.iter().any(|d| {
                d.container.contains("mp4") && d.video_codec.contains("hevc")
            }),
            "MP4 侧的 HEVC 直放不能被一起误伤掉"
        );
    }

    /// 能力表里加一条例外组合,声明侧要自动跟着变 —— 不许手写死。
    #[test]
    fn direct_play_profiles_are_derived_not_hard_coded() {
        let mut caps = AvkitCapabilities::current();
        // 造一张「MP4 装 hevc 也不行」的表(现实中不成立,只为验证派生关系)
        let extra: &'static [(&'static str, &'static str)] = &[("mp4", "hevc")];
        let original = caps.forbidden_container_video_pairs;
        caps.forbidden_container_video_pairs = extra;

        let profile = DeviceProfile::from_capabilities(&caps);
        for direct in &profile.direct_play_profiles {
            if direct.video_codec.split(',').any(|c| c == "hevc") {
                assert!(
                    !direct.container.split(',').any(|c| c == "mp4"),
                    "表改了但声明没跟着改:{direct:?}"
                );
            }
        }

        caps.forbidden_container_video_pairs = original;
        let restored = DeviceProfile::from_capabilities(&caps);
        assert!(
            restored.direct_play_profiles.iter().any(|d| {
                d.container.split(',').any(|c| c == "mp4") && d.video_codec.split(',').any(|c| c == "hevc")
            }),
            "恢复原表后 MP4 的 HEVC 直放声明应该回来"
        );
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
        for direct in &profile.direct_play_profiles {
            assert!(
                !direct.container.split(',').any(|c| c == "mkv" || c == "webm"),
                "MKV/WebM 不是 AVKit 原生支持,不该出现在声明里:{direct:?}"
            );
        }
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

    /// ⭐ P3 实测:转码交付形态**只能是 HLS**。
    ///
    /// 声明 `Protocol: "http"` 时服务端给 `stream.mp4`,响应头是
    /// `Accept-Ranges: none` + `Transfer-Encoding: chunked`,AVFoundation 判
    /// `-11850 AVErrorServerIncorrectlyConfigured` —— 四个转码样本一个都放不了。
    /// 声明 HLS 后服务端给 `master.m3u8`,同样的样本全部能起播
    /// (`Scripts/verify-avkit-playback.sh` 是那条证据)。
    ///
    /// 这条测试守的是「别顺手改回 progressive」——那不是口味问题,是能不能播。
    #[test]
    fn transcode_delivery_is_hls_only() {
        let profile = DeviceProfile::avkit();
        assert_eq!(
            profile.transcoding_profiles.len(),
            1,
            "只能声明一条转码 profile:两条并存时服务端挑哪条不受控"
        );
        let transcode = &profile.transcoding_profiles[0];
        assert_eq!(
            transcode.protocol, "hls",
            "转码交付形态必须是 hls;progressive(http)在 AVFoundation 上是 -11850"
        );
        // 转码目标是 h264/aac,所以容器是 ts 时不踩 `forbidden_container_video_pairs`
        // (那条例外约束的是**直放**声明,不是转码输出)
        assert!(
            !AvkitCapabilities::current().is_forbidden_pair(&transcode.container, &transcode.video_codec),
            "转码目标 {} × {} 恰好落在实测放不了的组合里",
            transcode.container,
            transcode.video_codec
        );
    }
}
