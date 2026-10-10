//! AVKit 兼容性表 —— 决策器唯一的「本机能不能放」依据。
//!
//! 来源:`docs/DECISIONS/avkit-rust-rearchitecture.md` 第 2 节。
//!
//! ⚠️ **该表全部为 🔶 多来源一致的二手结论,尚未在本机 AVPlayer 上实测**
//! (原文档 R7)。分支计划在 P3 阶段逐项实测并回填;实测若推翻某项,
//! 只需改本文件的常量,决策器与 DeviceProfile 都会跟着变 ——
//! 两者都从这张表派生,不允许各写一份(`DeviceProfile::avkit` 有断言防漂移)。
//!
//! 判定的方向性:**宁可多让服务端做一点,也不假装自己能放。**
//! 服务端被要求重封装/转码时,最坏是多花点 CPU;而客户端自以为能放时,
//! 表现是黑屏或无声 —— 且能骗过所有计数指标(第 4 节点名的静默失败)。

use crate::models::{MediaSource, MediaStream};

/// 服务端必须为某一维做的事。集合就是决策器的输出(第 4.1 节)。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ServerAction {
    /// 只改容器不改编码(DirectStream 的常见形态)
    RemuxContainer,
    /// 重编视频
    TranscodeVideo,
    /// 重编音频(DTS / TrueHD 的必经之路)
    TranscodeAudio,
    /// 把字幕烧进画面(位图字幕唯一出路)
    BurnSubtitle,
    /// 把字幕转成客户端能读的文本轨(会丢 ASS/SSA 样式)
    ConvertSubtitle,
}

impl ServerAction {
    /// 给日志与 UI 用的短名
    pub fn label(self) -> &'static str {
        match self {
            Self::RemuxContainer => "重封装容器",
            Self::TranscodeVideo => "转码视频",
            Self::TranscodeAudio => "转码音频",
            Self::BurnSubtitle => "烧录字幕",
            Self::ConvertSubtitle => "转换字幕为文本",
        }
    }
}

/// 单个维度的判定结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dimension {
    /// 客户端原生可放,服务端这一维什么都不用做
    Native,
    /// 服务端必须处理
    Needs(ServerAction),
    /// 响应里没有足够信息判定(如整份 `MediaStreams` 缺失)。
    /// ⛔ 不允许把「不知道」写成 `Native` —— 那正是静默失败的入口。
    Unverifiable,
}

impl Dimension {
    pub fn is_native(&self) -> bool {
        matches!(self, Self::Native)
    }
}

/// `AvkitCapabilities::audit` 的结果:逐维度 + 可读理由。
///
/// **容器 / 视频 / 音频**三维决定播放路径(`path_actions`);
/// **字幕**维只报告「要显示这条字幕时服务端得做什么」(`subtitle_action`),
/// 不单独把 DirectStream 顶成 Transcode —— 源里躺一条位图字幕轨、
/// 而用户根本没开字幕时,不该为此整片重编(该行为由 P3 按选中轨刷新)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybackAudit {
    pub container: Dimension,
    pub video: Dimension,
    pub audio: Dimension,
    pub subtitle: Dimension,
    /// 只含非 `Native` 维度的可读理由,顺序固定(容器 → 视频 → 音频 → 字幕)
    pub notes: Vec<String>,
}

impl PlaybackAudit {
    /// 决定播放路径的服务端动作(容器 / 视频 / 音频),去重且顺序稳定。
    pub fn path_actions(&self) -> Vec<ServerAction> {
        let mut actions: Vec<ServerAction> = [&self.container, &self.video, &self.audio]
            .into_iter()
            .filter_map(|d| match d {
                Dimension::Needs(a) => Some(*a),
                _ => None,
            })
            .collect();
        actions.sort_unstable();
        actions.dedup();
        actions
    }

    /// 字幕维所需的处理;`Native` 或 `Unverifiable` 时为 `None`。
    pub fn subtitle_action(&self) -> Option<ServerAction> {
        match self.subtitle {
            Dimension::Needs(a) => Some(a),
            _ => None,
        }
    }

    /// 有哪几维「判不了」。调用方据此决定要不要在日志里留一句。
    pub fn unverifiable_dimensions(&self) -> Vec<&'static str> {
        [
            ("容器", &self.container),
            ("视频", &self.video),
            ("音频", &self.audio),
            ("字幕", &self.subtitle),
        ]
        .into_iter()
        .filter_map(|(name, d)| matches!(d, Dimension::Unverifiable).then_some(name))
        .collect()
    }
}

/// 客户端(AVKit)的原生能力表。
///
/// 常量全部小写;查表前调用方不必自己规范化。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AvkitCapabilities {
    /// 能被系统解复用器直接打开的容器(第 2 节:MKV / WebM 不在内)
    pub native_containers: &'static [&'static str],
    pub native_video_codecs: &'static [&'static str],
    pub native_audio_codecs: &'static [&'static str],
    /// 容器内的文本字幕轨,系统能直接读
    pub native_subtitle_codecs: &'static [&'static str],
    /// 文本字幕,但系统读不了容器里的原格式 / 或会丢样式,需服务端转文本
    pub convertible_subtitle_codecs: &'static [&'static str],
    /// 位图字幕:没有系统渲染通路,只能烧录
    pub bitmap_subtitle_codecs: &'static [&'static str],
    /// 表的版本号。回填 P3 实测结论时改这里,决策结果里能对上。
    pub revision: &'static str,
}

impl AvkitCapabilities {
    /// 当前分支采用的能力表(第 2 节)。
    pub const fn current() -> Self {
        Self {
            // MP4 / MOV / M4V / MPEG-TS。`m2ts` / `mts` 是 Emby 对同族的其它写法。
            // ⚠️ `avi` / `mpeg` 官方列为「仅老编码、常见黑屏」→ 刻意**不**算原生,
            //    宁可让服务端重封装。
            native_containers: &["mp4", "m4v", "mov", "ts", "m2ts", "mts", "mpegts"],
            // HEVC 含 Main/Main10、HDR10、HLG、DV 5/8.1/8.4。
            // ⚠️ VP9 只能经 HLS,容器内直放不成立 → 不算原生。
            native_video_codecs: &["h264", "hevc", "av1", "prores"],
            // DTS / TrueHD 不支持(HomePod / Apple TV 的「全景声」只走 E-AC-3,与 TrueHD 不是一回事)。
            native_audio_codecs: &["aac", "ac3", "eac3", "alac", "flac", "mp3"],
            // WebVTT / TTML / 3GPP 定时文本。
            native_subtitle_codecs: &["webvtt", "vtt", "ttml", "mov_text", "eia_608"],
            // ⚠️ `subrip`(srt)与 `ass`/`ssa` 都算「文本但需转换」:
            //    - srt:AVKit 能不能从媒体选择组里直读,二手来源不一致,P3 实测前按需转换处理;
            //    - ass/ssa:能读,但样式会被丢弃,不如直接让服务端给纯文本。
            //    这一条最可能在 P3 被推翻,推翻后把 codec 从本表挪进
            //    `native_subtitle_codecs` 即可,两侧派生都会跟着变。
            convertible_subtitle_codecs: &["subrip", "srt", "ass", "ssa", "text", "smi"],
            // PGS / VOBSUB / DVB / XSUB:没有系统渲染通路。
            bitmap_subtitle_codecs: &[
                "hdmv_pgs_subtitle",
                "pgs",
                "pgssub",
                "dvd_subtitle",
                "dvdsub",
                "vobsub",
                "dvb_subtitle",
                "dvbsub",
                "xsub",
            ],
            revision: "avkit-capability/2026-10-10 (第 2 节 🔶,未在本机实测)",
        }
    }

    /// 逐维度判定一个 MediaSource。
    pub fn audit(&self, source: &MediaSource) -> PlaybackAudit {
        let mut notes = Vec::new();

        let container = match source.container.as_deref() {
            None => Dimension::Unverifiable,
            Some(raw) => {
                let normalized = raw.trim().to_ascii_lowercase();
                if self.native_containers.contains(&normalized.as_str()) {
                    Dimension::Native
                } else {
                    notes.push(format!(
                        "容器 {raw} 不是 AVKit 原生支持,需服务端重封装"
                    ));
                    Dimension::Needs(ServerAction::RemuxContainer)
                }
            }
        };

        // `MediaStreams` 整个缺失时,视频/音频/字幕三维都判不了 ——
        // 不假装它们没问题。
        let streams_missing = source.media_streams.is_none();

        let video = if streams_missing {
            Dimension::Unverifiable
        } else {
            let offenders: Vec<&MediaStream> = source
                .streams_of("Video")
                .into_iter()
                .filter(|s| !self.is_native_codec(s.codec.as_deref(), self.native_video_codecs))
                .collect();
            if source.streams_of("Video").is_empty() {
                // 无视频轨(纯音频媒体):这一维没有要求
                Dimension::Native
            } else if offenders.is_empty() {
                Dimension::Native
            } else {
                notes.push(format!(
                    "视频编码 {} 需服务端转码",
                    describe_codecs(&offenders)
                ));
                Dimension::Needs(ServerAction::TranscodeVideo)
            }
        };

        let audio = if streams_missing {
            Dimension::Unverifiable
        } else {
            let all = source.streams_of("Audio");
            let offenders: Vec<&MediaStream> = all
                .iter()
                .copied()
                .filter(|s| !self.is_native_codec(s.codec.as_deref(), self.native_audio_codecs))
                .collect();
            if all.is_empty() || offenders.is_empty() {
                Dimension::Native
            } else {
                // ⚠️ 过近似:只要源里有**任意**一条非原生音轨就要求转码,
                //    不区分用户实际选哪条。P3 接上音轨选择后要按选中的轨判。
                notes.push(format!(
                    "音轨编码 {} 需服务端转码",
                    describe_codecs(&offenders)
                ));
                Dimension::Needs(ServerAction::TranscodeAudio)
            }
        };

        let subtitle = if streams_missing {
            Dimension::Unverifiable
        } else {
            self.audit_subtitles(source, &mut notes)
        };

        PlaybackAudit {
            container,
            video,
            audio,
            subtitle,
            notes,
        }
    }

    fn audit_subtitles(&self, source: &MediaSource, notes: &mut Vec<String>) -> Dimension {
        let tracks = source.streams_of("Subtitle");
        if tracks.is_empty() {
            return Dimension::Native;
        }

        let is_bitmap = |s: &MediaStream| {
            // `IsTextSubtitleStream == false` 是服务端给的直接判据;
            // 编码表是兜底(字段缺失或服务端用了个我们不认识的位图编码)。
            if s.is_text_subtitle_stream == Some(false) {
                return true;
            }
            s.codec
                .as_deref()
                .map(|c| self.bitmap_subtitle_codecs.contains(&c.to_ascii_lowercase().as_str()))
                .unwrap_or(false)
        };

        if tracks.iter().any(|s| is_bitmap(s)) {
            notes.push("存在位图字幕轨(PGS/VOBSUB 类),客户端渲染不了,只能服务端烧录".to_string());
            return Dimension::Needs(ServerAction::BurnSubtitle);
        }

        let convertible: Vec<&MediaStream> = tracks
            .iter()
            .copied()
            .filter(|s| {
                !self.is_native_codec(s.codec.as_deref(), self.native_subtitle_codecs)
            })
            .collect();
        if convertible.is_empty() {
            Dimension::Native
        } else {
            notes.push(format!(
                "字幕 {} 需服务端转成客户端可读的文本轨(ASS/SSA 会丢样式)",
                describe_codecs(&convertible)
            ));
            Dimension::Needs(ServerAction::ConvertSubtitle)
        }
    }

    fn is_native_codec(&self, codec: Option<&str>, native: &[&str]) -> bool {
        codec
            .map(|c| native.contains(&c.trim().to_ascii_lowercase().as_str()))
            .unwrap_or(false)
    }
}

/// 把若干轨的编码拼成 `h264/hevc` 这样的可读串,用于解释文案。
fn describe_codecs(tracks: &[&MediaStream]) -> String {
    let mut names: Vec<String> = tracks
        .iter()
        .map(|s| {
            s.codec
                .clone()
                .unwrap_or_else(|| "未知编码".to_string())
        })
        .collect();
    names.sort();
    names.dedup();
    names.join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source_with(json: &str) -> MediaSource {
        serde_json::from_str(json).expect("测试用 MediaSource 应能解码")
    }

    #[test]
    fn mp4_h264_aac_is_natively_playable() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mp4",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"aac"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);

        assert_eq!(audit.container, Dimension::Native);
        assert_eq!(audit.video, Dimension::Native);
        assert_eq!(audit.audio, Dimension::Native);
        assert_eq!(audit.subtitle, Dimension::Native);
        assert!(audit.path_actions().is_empty());
        assert!(audit.notes.is_empty());
    }

    #[test]
    fn mkv_needs_remux_and_dts_needs_audio_transcode() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mkv",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"dts"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);

        assert_eq!(audit.container, Dimension::Needs(ServerAction::RemuxContainer));
        assert_eq!(audit.video, Dimension::Native);
        assert_eq!(audit.audio, Dimension::Needs(ServerAction::TranscodeAudio));
        assert_eq!(
            audit.path_actions(),
            vec![ServerAction::RemuxContainer, ServerAction::TranscodeAudio]
        );
    }

    #[test]
    fn pgs_is_burn_in_and_does_not_force_the_path() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mp4",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"aac"},
                    {"Index":2,"Type":"Subtitle","Codec":"hdmv_pgs_subtitle",
                     "IsTextSubtitleStream": false}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);

        assert_eq!(audit.subtitle, Dimension::Needs(ServerAction::BurnSubtitle));
        assert_eq!(audit.subtitle_action(), Some(ServerAction::BurnSubtitle));
        // 关键性质:源里躺一条位图字幕轨、用户没开字幕时,不该整片重编。
        assert!(
            audit.path_actions().is_empty(),
            "字幕维不该把播放路径顶成转码,实际:{:?}",
            audit.path_actions()
        );
    }

    /// `IsTextSubtitleStream=false` 但编码不认识时,仍必须判成位图。
    #[test]
    fn unknown_codec_with_text_flag_false_is_still_bitmap() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mp4",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"aac"},
                    {"Index":2,"Type":"Subtitle","Codec":"exotic_bitmap",
                     "IsTextSubtitleStream": false}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);
        assert_eq!(audit.subtitle, Dimension::Needs(ServerAction::BurnSubtitle));
    }

    #[test]
    fn ass_is_convertible_not_bitmap() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mkv",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"aac"},
                    {"Index":2,"Type":"Subtitle","Codec":"ass","IsTextSubtitleStream": true}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);
        assert_eq!(audit.subtitle, Dimension::Needs(ServerAction::ConvertSubtitle));
    }

    /// 缺信息就是缺信息:⛔ 不能悄悄按「没问题」处理。
    #[test]
    fn missing_streams_are_unverifiable_not_native() {
        let source = source_with(r#"{"Id":"s","Container":"mp4"}"#);
        let audit = AvkitCapabilities::current().audit(&source);

        assert_eq!(audit.video, Dimension::Unverifiable);
        assert_eq!(audit.audio, Dimension::Unverifiable);
        assert_eq!(audit.subtitle, Dimension::Unverifiable);
        assert_eq!(audit.unverifiable_dimensions(), vec!["视频", "音频", "字幕"]);
        // 容器是可判的
        assert_eq!(audit.container, Dimension::Native);
        // 判不了的维度不进 path_actions —— 避免无凭据地要求转码
        assert!(audit.path_actions().is_empty());
    }

    #[test]
    fn unknown_container_needs_remux() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "webm",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"aac"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);
        assert_eq!(audit.container, Dimension::Needs(ServerAction::RemuxContainer));
    }

    #[test]
    fn codec_matching_is_case_insensitive() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "MP4",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"H264"},
                    {"Index":1,"Type":"Audio","Codec":"AAC"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);
        assert_eq!(audit.container, Dimension::Native);
        assert_eq!(audit.video, Dimension::Native);
        assert_eq!(audit.audio, Dimension::Native);
    }
}
