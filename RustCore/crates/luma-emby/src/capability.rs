//! AVKit 兼容性表 —— 决策器唯一的「本机能不能放」依据。
//!
//! 来源:`docs/DECISIONS/avkit-rust-rearchitecture.md` 第 2 节。
//!
//! **状态(2026-10-10,P3)**:该表已在本机 AVFoundation 上**逐项实测**
//! (证据:`Scripts/probe-avkit-capability.sh`,31 项断言,3 条原假设被推翻,
//!  结论写进文档第 2.1 节)。实测推翻的三条已回填到本文件:
//!
//! 1. **HEVC 在 MPEG-TS 里 AVFoundation 连视频轨都不暴露** —— 容器维与视频维
//!    **不是独立的**,见 [`AvkitCapabilities::forbidden_container_video_pairs`]。
//! 2. MP4 里的 HEVC 必须 fourCC = `hvc1`;`hev1` 直接 `playable=false`。
//!    这不是我们能控制的(取决于服务端怎么封装),只能记着。
//! 3. `mp3` 装在 MP4 里会被静默丢弃 → 从原生音频表里摘掉。
//!
//! ⚠️ 仍未实测:AV1 / ProRes 的容器组合、位图字幕的烧录效果、HLS 与转码流的
//! seek 语义(那是 P3 播放内核的题目)。
//!
//! 判定的方向性:**宁可多让服务端做一点,也不假装自己能放。**
//! 服务端被要求重封装/转码时,最坏是多花点 CPU;而客户端自以为能放时,
//! 表现是黑屏或无声 —— 且能骗过所有计数指标(第 4 节点名的静默失败)。
//!
//! ⭐ 实测补充了这条依据的**机制**:AVFoundation 遇到不认识的编码不是报错,
//! 而是把那条轨**悄悄从 `AVAssetTrack` 列表里删掉**
//! (实测:MKV 之外,MP4 里的 DTS / TrueHD / MP3,TS 里的 HEVC 都是这个行为;
//! 一个只剩音轨的 TS 能正常 `play()` 且时间照走,`errorLog` 干干净净)。
//! 所以指望「拿不到就报错」是不成立的,判定必须发生在建流之前。

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
    /// ⭐ **容器 × 视频编码 的例外组合** —— `(容器, 视频编码)`。
    ///
    /// 加这一栏的原因是 P3 实测推翻了「容器与视频编码是两个独立维度」这个
    /// 默认假设:HEVC 装在 MP4 里没问题,装在 MPEG-TS 里 AVFoundation
    /// **连视频轨都不列出**(实测:TS 里 hevc 轨消失、只剩音轨,而
    /// `AVPlayerItem` 照样 `readyToPlay` + `play()`,时间照走、`errorLog` 为空
    /// —— 即「有声音没画面」的静默失败)。
    ///
    /// ⛔ 判到这里的组合**不能**当成原生直放;按容器维处理(让服务端重封装)。
    pub forbidden_container_video_pairs: &'static [(&'static str, &'static str)],
    /// 表的版本号。回填 P3 实测结论时改这里,决策结果里能对上。
    pub revision: &'static str,
}

impl AvkitCapabilities {
    /// 当前分支采用的能力表(第 2 节 + 2.1 节实测回填)。
    pub const fn current() -> Self {
        Self {
            // MP4 / MOV / M4V / MPEG-TS。`m2ts` / `mts` 是 Emby 对同族的其它写法。
            // ⚠️ `avi` / `mpeg` 官方列为「仅老编码、常见黑屏」→ 刻意**不**算原生,
            //    宁可让服务端重封装。
            native_containers: &["mp4", "m4v", "mov", "ts", "m2ts", "mts", "mpegts"],
            // HEVC 含 Main/Main10、HDR10、HLG、DV 5/8.1/8.4。
            // ⚠️ VP9 只能经 HLS,容器内直放不成立 → 不算原生。
            native_video_codecs: &["h264", "hevc", "av1", "prores"],
            // ⚠️ 实测(2026-10-10)把 `mp3` 从这里摘掉:MP4 里的 MP3 轨会被
            //    AVFoundation **静默丢弃**(轨数对不上,`playable` 仍是 true)。
            //    裸 `.mp3` 文件本身是支持的(fourCC `.mp3`),但本项目是视频客户端,
            //    能力表问的是「视频源里的音轨」—— 而把 mp3 音频重封装进 mp4
            //    正是服务端会做的事(老 AVI 片源)。代价只是服务端 mp3→aac,
            //    远小于「有画面没声音」。若将来支持音乐库,需重新评估这一条。
            native_audio_codecs: &["aac", "ac3", "eac3", "alac", "flac"],
            // WebVTT / TTML / 3GPP 定时文本(实测:`mov_text` 进 MP4 后,
            // `AVMediaSelectionGroup(.legible)` 里能看到它)。
            native_subtitle_codecs: &["webvtt", "vtt", "ttml", "mov_text", "eia_608"],
            // ⚠️ `subrip`(srt)与 `ass`/`ssa` 都算「文本但需转换」:
            //    - srt:实测**没能造出**「MP4 里原样封装 srt」的样本(ffmpeg、
            //      Emby 都只会把它转成 mov_text 或 vtt),所以「AVKit 能不能直读
            //      容器里的 srt」这个问题在本机无法证实 → 按需转换处理,方向安全;
            //    - ass/ssa:能读,但样式会被丢弃,不如直接让服务端给纯文本。
            //    实测把 pos 侧坐实了:`mov_text` **能**进 legible 组,说明
            //    「服务端转文本」这条出路是通的(这正是本表要求的动作)。
            convertible_subtitle_codecs: &["subrip", "srt", "ass", "ssa", "text", "smi"],
            // PGS / VOBSUB / DVB / XSUB:没有系统渲染通路。
            // 实测补充:PGS 进 MPEG-TS 后 legible 组为空(且那条轨整条不暴露)。
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
            // ⭐ 实测:HEVC 进 MPEG-TS → AVFoundation 只认下音轨(视频轨消失),
            //    而 `play()` 照样成功。AV1 没有实测样本,按同一族的理由保守排除
            //    (TS 里 AV1 也不是 Apple 的既有封装形态);ProRes 是 MOV 专属,
            //    本条对 TS 家族一并覆盖。
            forbidden_container_video_pairs: &[
                ("ts", "hevc"),
                ("m2ts", "hevc"),
                ("mts", "hevc"),
                ("mpegts", "hevc"),
                ("ts", "av1"),
                ("m2ts", "av1"),
                ("mts", "av1"),
                ("mpegts", "av1"),
                ("ts", "prores"),
                ("m2ts", "prores"),
                ("mts", "prores"),
                ("mpegts", "prores"),
            ],
            revision: "avkit-capability/2026-10-10 (第 2 节 + 2.1 本机实测)",
        }
    }

    /// 某个容器里**能原生直放**的视频编码 —— 从总表里减去例外组合。
    ///
    /// `DeviceProfile` 用它拆 `DirectPlayProfile` 用:一条 `DirectPlayProfile` 里的
    /// `Container × VideoCodec` 是**合取**关系,所以「TS 能装 H.264 但不能装 HEVC」
    /// 这种例外必须拆成两条声明,不能把所有容器和所有编码并成一条。
    pub fn native_video_codecs_for(&self, container: &str) -> Vec<&'static str> {
        self.native_video_codecs
            .iter()
            .copied()
            .filter(|codec| !self.is_forbidden_pair(container, codec))
            .collect()
    }

    /// 这组「容器 × 视频编码」是不是实测出来的例外组合。
    pub fn is_forbidden_pair(&self, container: &str, video_codec: &str) -> bool {
        let container = container.trim().to_ascii_lowercase();
        let codec = video_codec.trim().to_ascii_lowercase();
        self.forbidden_container_video_pairs
            .iter()
            .any(|(c, v)| *c == container && *v == codec)
    }


    /// 逐维度判定一个 MediaSource。
    pub fn audit(&self, source: &MediaSource) -> PlaybackAudit {
        let mut notes = Vec::new();

        let container = match source.container.as_deref() {
            None => Dimension::Unverifiable,
            Some(raw) => {
                let normalized = raw.trim().to_ascii_lowercase();
                if !self.native_containers.contains(&normalized.as_str()) {
                    notes.push(format!(
                        "容器 {raw} 不是 AVKit 原生支持,需服务端重封装"
                    ));
                    Dimension::Needs(ServerAction::RemuxContainer)
                } else {
                    // ⭐ 容器对了还不够:容器 × 视频编码 有实测出来的例外组合。
                    //    (HEVC 进 MPEG-TS 时 AVFoundation 连视频轨都不列出,
                    //     而播放照样"成功" —— 只出声音不出画面。)
                    let offenders: Vec<String> = source
                        .streams_of("Video")
                        .into_iter()
                        .filter_map(|s| s.codec.clone())
                        .filter(|c| self.is_forbidden_pair(&normalized, c))
                        .collect();
                    if offenders.is_empty() {
                        Dimension::Native
                    } else {
                        let mut names = offenders.clone();
                        names.sort();
                        names.dedup();
                        notes.push(format!(
                            "容器 {raw} 装 {} 时 AVFoundation 认不出视频轨(只能换容器重封装)",
                            names.join("/")
                        ));
                        Dimension::Needs(ServerAction::RemuxContainer)
                    }
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

    // ───────────────────────── P3 实测回填(2026-10-10)新增的断言 ─────────────────────────

    /// ⭐ 本机实测:HEVC 进 MPEG-TS 后 AVFoundation **连视频轨都不列出**
    /// (文件里确实有,ffprobe 能看见),而 `AVPlayerItem` 照样 readyToPlay +
    /// `play()`,时间照走、`errorLog` 为空 —— 就是「有声音没画面」。
    /// 所以这一对组合必须走重封装,不能当原生直放。
    #[test]
    fn hevc_in_mpegts_is_not_a_native_combination() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mpegts",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"hevc"},
                    {"Index":1,"Type":"Audio","Codec":"aac"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);

        assert_eq!(
            audit.container,
            Dimension::Needs(ServerAction::RemuxContainer),
            "HEVC 装 MPEG-TS 时不能当容器原生"
        );
        // 视频编码本身是支持的 —— 问题出在组合上,不是编码上
        assert_eq!(audit.video, Dimension::Native);
        assert_eq!(audit.audio, Dimension::Native);
        assert_eq!(audit.path_actions(), vec![ServerAction::RemuxContainer]);
        assert!(
            audit.notes.iter().any(|n| n.contains("视频轨")),
            "理由要点明「认不出视频轨」,实际:{:?}",
            audit.notes
        );
    }

    /// 对照组:同一容器装 H.264 是**实测通过**的,不能被上面那条规则误伤。
    #[test]
    fn h264_in_mpegts_stays_native() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mpegts",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"ac3"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);

        assert_eq!(audit.container, Dimension::Native);
        assert_eq!(audit.video, Dimension::Native);
        assert_eq!(audit.audio, Dimension::Native);
        assert!(audit.path_actions().is_empty());
    }

    /// 同一个编码换个容器就没事了 —— 说明规则钉的是「组合」而不是编码。
    #[test]
    fn hevc_in_mp4_stays_native() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mp4",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"hevc"},
                    {"Index":1,"Type":"Audio","Codec":"aac"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);
        assert_eq!(audit.container, Dimension::Native);
        assert_eq!(audit.video, Dimension::Native);
    }

    /// ⭐ 本机实测:MP3 装进 MP4 后音轨被**静默丢弃**(轨数对不上,
    /// 而 `playable` 仍是 true)→ 从原生音频表里摘掉,让服务端转码。
    #[test]
    fn mp3_audio_is_not_native_anymore() {
        let source = source_with(
            r#"{
                "Id": "s", "Container": "mp4",
                "MediaStreams": [
                    {"Index":0,"Type":"Video","Codec":"h264"},
                    {"Index":1,"Type":"Audio","Codec":"mp3"}
                ]
            }"#,
        );
        let audit = AvkitCapabilities::current().audit(&source);

        assert_eq!(audit.audio, Dimension::Needs(ServerAction::TranscodeAudio));
        assert_eq!(audit.path_actions(), vec![ServerAction::TranscodeAudio]);
        // 容器与视频都不该受影响
        assert_eq!(audit.container, Dimension::Native);
        assert_eq!(audit.video, Dimension::Native);
    }

    /// 能力表版本号里必须留下「已实测」这个事实 —— 别让后人以为还是二手推断。
    #[test]
    fn revision_records_the_local_measurement() {
        let revision = AvkitCapabilities::current().revision;
        assert!(revision.contains("avkit-capability"), "{revision}");
        assert!(revision.contains("实测"), "版本号应记下已实测,实际:{revision}");
    }
}
