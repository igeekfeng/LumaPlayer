//! P2 门禁:对**四类真实片源**断言决策结果。
//!
//! 数据来自 `Tools/emby-dev/`(Emby 4.9.5.0)上真实抓到并脱敏的 `PlaybackInfo` 响应
//! (`docs/API_CONTRACT.md` 9.3),⛔ 不是手写编造的。
//!
//! ⚠️ 本地实例的结论**不能**推广成「真实服务器也如此」——
//! 它只代表 `4.9.5.0` 这一个版本、这一种部署形态(`Tools/emby-dev/README.md` 的边界)。
//!
//! 断言的口径是 `avkit-rust-rearchitecture.md` 第 8 节 P2 那一行:
//! 「对 4 类片源断言决策结果:MP4/H264/AAC、MKV/H264/AAC、MKV/H264/DTS、MKV/HEVC/PGS」。

use std::fs;
use std::path::PathBuf;

use luma_emby::{
    AvkitCapabilities, PlaybackError, PlaybackInfoResponse, PlaybackMethod, ServerAction,
};

/// fixture 与 Swift 侧共用一份(`LumaPlayerTests/Fixtures/`),⛔ 不在这边另存一套 ——
/// 两套 fixture 必然漂移。
fn fixture(name: &str) -> PlaybackInfoResponse {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../LumaPlayerTests/Fixtures/Playback");
    let path = dir.join(name);
    assert!(
        path.is_file(),
        "找不到 fixture {}\n\
         —— 如果 `LumaPlayerTests/` 挪了位置,这条断言就是里外两层路径约定失配的报警器。",
        path.display()
    );
    let raw = fs::read_to_string(&path).expect("读 fixture");
    serde_json::from_str(&raw).unwrap_or_else(|e| panic!("解析 {} 失败:{e}", path.display()))
}

fn decide(name: &str) -> Result<luma_emby::PlaybackDecision, PlaybackError> {
    luma_emby::decision::decide(&fixture(name), &AvkitCapabilities::current())
}

// ---------------------------------------------------------------- 第 1 类:MP4/H264/AAC

/// 四维全原生 → 服务端什么都不用做,直接串流。
#[test]
fn mp4_h264_aac_streams_directly() {
    let decision = decide("playback_mp4_h264_aac.json").expect("应能决策");

    assert_eq!(decision.method, PlaybackMethod::DirectStream);
    assert_eq!(decision.method.wire_name(), "DirectStream");
    assert!(
        decision.audit.path_actions().is_empty(),
        "四维全原生,不该要求服务端做任何事,实际:{:?}",
        decision.audit.path_actions()
    );
    assert!(decision.audit.unverifiable_dimensions().is_empty());
    assert!(decision.direct_stream_url.is_some(), "应带上服务端给的直连地址");
    assert!(decision.transcoding_url.is_none());
    assert!(decision.capability_revision.contains("avkit-capability"));
}

/// 同一条素材还带一条**外挂** `.zh.srt` 字幕轨。它不影响播放路径
/// (字幕维不参与 path 判定),但必须被如实报出来 —— 它的编码是 `srt`,
/// 按第 2 节的表要服务端转成客户端能读的文本轨。
#[test]
fn mp4_h264_aac_reports_external_srt_needing_conversion() {
    let decision = decide("playback_mp4_h264_aac.json").expect("应能决策");

    assert_eq!(
        decision.audit.subtitle_action(),
        Some(ServerAction::ConvertSubtitle),
        "外挂 srt 应被记为「需转文本」"
    );
    assert_eq!(decision.method, PlaybackMethod::DirectStream);
}

// ---------------------------------------------------------------- 第 2 类:MKV/H264/AAC

/// 只有容器这一维不原生 → 服务端重封装(不重编码)后交回来。
#[test]
fn mkv_h264_aac_needs_container_remux() {
    let decision = decide("playback_mkv_h264_aac.json").expect("应能决策");

    assert_eq!(decision.method, PlaybackMethod::Transcode);
    assert_eq!(decision.method.display_name(), "服务端转码");
    assert_eq!(
        decision.audit.path_actions(),
        vec![ServerAction::RemuxContainer],
        "MKV 只该触发容器重封装"
    );
    // 服务端真的给了转码入口,而且它确实是唯一合法的入口
    assert!(decision.transcoding_url.is_some());
    assert_eq!(decision.transcoding_sub_protocol.as_deref(), Some("http"));
    assert!(
        !decision.audit.notes.is_empty(),
        "非原生维度必须给出可读理由"
    );
}

/// 内嵌的两条 `subrip` 字幕同样要转文本(服务端实际转成了 `mov_text` 内嵌)。
#[test]
fn mkv_h264_aac_reports_embedded_subrip_needing_conversion() {
    let decision = decide("playback_mkv_h264_aac.json").expect("应能决策");
    assert_eq!(
        decision.audit.subtitle_action(),
        Some(ServerAction::ConvertSubtitle)
    );
}

// ---------------------------------------------------------------- 第 3 类:MKV/H264/DTS

/// 容器要重封装 **且** 音轨要转码(DTS 不在 Apple 支持集里)。
#[test]
fn mkv_h264_dts_needs_remux_plus_audio_transcode() {
    let decision = decide("playback_mkv_h264_dts.json").expect("应能决策");

    assert_eq!(decision.method, PlaybackMethod::Transcode);
    assert_eq!(
        decision.audit.path_actions(),
        vec![ServerAction::RemuxContainer, ServerAction::TranscodeAudio]
    );
    // 视频编码 h264 是原生的 —— 这一维不该被牵连
    assert!(
        !decision
            .audit
            .path_actions()
            .contains(&ServerAction::TranscodeVideo),
        "h264 不该要求重编视频"
    );
    assert!(decision.audit.subtitle_action().is_none(), "这条素材没有字幕轨");
}

// ---------------------------------------------------------------- 第 4 类:MKV/HEVC/PGS

/// HEVC 是原生的,所以只有容器维触发重封装;位图字幕单独报「需烧录」。
#[test]
fn mkv_hevc_pgs_needs_remux_and_reports_burn_in() {
    let decision = decide("playback_mkv_hevc_pgs.json").expect("应能决策");

    assert_eq!(decision.method, PlaybackMethod::Transcode);
    assert_eq!(
        decision.audit.path_actions(),
        vec![ServerAction::RemuxContainer],
        "HEVC 原生,唯一要服务端做的是重封装"
    );
    assert_eq!(
        decision.audit.subtitle_action(),
        Some(ServerAction::BurnSubtitle),
        "PGS 位图字幕只能烧录"
    );
}

// ---------------------------------------------------------------- 静默失败守卫(反面样本)

/// ⭐ 这条是本阶段新增的安全性质。
///
/// fixture 是同一台服务器在**旧的**「容器/编码不限」profile 下对同一条 MKV 的响应:
/// 服务端认为可以直接串流(`SupportsDirectStream: true`),既不给 `TranscodingUrl`,
/// 而容器是 MKV —— AVKit 打不开。照 4.4 的老算法,这里会一路走到
/// `PlaybackMethod::DirectStream`,然后在播放器上表现为黑屏/无声,而所有指标正常。
///
/// 新决策器选择**报错**:`ServerOfferedUnplayableDirectStream`。
#[test]
fn unplayable_direct_stream_is_refused_instead_of_silently_played() {
    let err = decide("playback_mkv_direct_stream_silent_failure.json").unwrap_err();

    match err {
        PlaybackError::ServerOfferedUnplayableDirectStream { actions, notes } => {
            assert_eq!(actions, vec![ServerAction::RemuxContainer]);
            assert!(!notes.is_empty());
            assert!(
                notes.join(" ").contains("mkv"),
                "理由里应点名是容器的问题:{notes:?}"
            );
        }
        other => panic!("应命中静默失败守卫,实际 {other:?}"),
    }
}

/// 守卫的可解释文案要能让用户看懂「是服务器没给转码地址」,
/// 而不是一句「播放失败」。
#[test]
fn silent_failure_message_names_the_missing_piece() {
    let err = decide("playback_mkv_direct_stream_silent_failure.json").unwrap_err();
    let message = err.user_message();

    assert!(message.contains("重封装容器"), "文案应点明需要服务端做什么:{message}");
    assert!(message.contains("转码地址"), "文案应点明缺的是转码地址:{message}");
}

// ---------------------------------------------------------------- fixture 自身的一致性

/// 五份 fixture 都必须是**真实**响应形态:有 `MediaSources` 或 `ErrorCode`,
/// 且脱敏干净(⛔ 不允许残留真实 token / 服务端路径)。
#[test]
fn fixtures_are_real_responses_and_sanitized() {
    for name in [
        "playback_mp4_h264_aac.json",
        "playback_mkv_h264_aac.json",
        "playback_mkv_h264_dts.json",
        "playback_mkv_hevc_pgs.json",
        "playback_mkv_direct_stream_silent_failure.json",
    ] {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../LumaPlayerTests/Fixtures/Playback");
        let raw = fs::read_to_string(dir.join(name)).expect("读 fixture");

        assert!(raw.contains("MediaSources"), "{name} 缺 MediaSources");
        assert!(!raw.contains("/mnt/media/"), "{name} 残留服务端路径");
        assert!(
            !raw.contains("api_key=\"") && !contains_real_api_key(&raw),
            "{name} 残留未脱敏的 api_key"
        );
        assert!(!raw.contains("_synthetic"), "{name} 是真实响应,不该带 _synthetic");
    }
}

fn contains_real_api_key(raw: &str) -> bool {
    raw.split("api_key=")
        .skip(1)
        .any(|tail| !tail.starts_with("FAKE_TOKEN"))
}
