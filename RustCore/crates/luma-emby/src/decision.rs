//! 播放决策器 —— `API_CONTRACT.md` 4.4 的算法 + AVKit 兼容性校验。
//!
//! **纯函数**:不持状态、不发网络请求、不读凭据。输入一份 `PlaybackInfo` 响应
//! 与一张能力表,输出一个 [`PlaybackDecision`] 或抛 [`PlaybackError`]。
//! 这样所有分支都能用 fixture 覆盖,不需要真实服务器。
//!
//! ## 与 4.4 原算法的关系
//!
//! 前六步照抄 4.4(不发明端点、不自己拼 URL)。新增的是**第 4.5 步**:
//! 在「服务端说可以 DirectStream」之后,用本机能力表**复核一遍**。
//!
//! 这一步是 `avkit-rust-rearchitecture.md` 第 4 节点名的东西:
//! 声明写错时服务端会返回一个客户端放不了的流,**决策器不会报错**,
//! 表现是黑屏或无声,而所有计数指标都正常(和 `PITFALLS.md` 里
//! FBO 写死 0 那次一样能骗过全部指标)。换成 AVKit 后这个风险从「设计代价」
//! 变成「必须堵住的漏洞」,所以在决策层堵,而不是等播放器黑屏。

use crate::capability::{AvkitCapabilities, PlaybackAudit, ServerAction};
use crate::models::PlaybackInfoResponse;

/// 上报与展示用的播放方式(`API_CONTRACT.md` 4.2 的 `PlayMethod` 列)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaybackMethod {
    DirectStream,
    Transcode,
}

impl PlaybackMethod {
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::DirectStream => "DirectStream",
            Self::Transcode => "Transcode",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::DirectStream => "直接串流",
            Self::Transcode => "服务端转码",
        }
    }
}

/// 决策结果。
#[derive(Debug, Clone, PartialEq)]
pub struct PlaybackDecision {
    pub method: PlaybackMethod,
    /// 逐维度判定(容器 / 视频 / 音频 / 字幕),UI 与排障都读它
    pub audit: PlaybackAudit,
    pub media_source_id: String,
    pub play_session_id: String,
    /// 服务端给的直连地址(相对 API 根,带 `api_key`)。取用时由 URL 构造层剥掉。
    pub direct_stream_url: Option<String>,
    /// 服务端给的转码地址(相对路径)。**唯一**合法的转码入口。
    pub transcoding_url: Option<String>,
    pub transcoding_sub_protocol: Option<String>,
    /// 判定所依据的能力表版本 —— 回填 P3 实测结论后能对上
    pub capability_revision: String,
}

/// 决策失败的原因。都要给出**可解释**的文案。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlaybackError {
    /// 服务端明确拒绝(响应里 `ErrorCode` 非空)
    ServerRejected { code: String },
    /// 响应里没有任何 MediaSource
    NoMediaSource,
    /// 响应缺少构造播放所必需的字段(`API_CONTRACT.md` 8.1)
    MissingRequiredField { name: String },
    /// 选中的源既不能 DirectStream,也没有 `TranscodingUrl`
    NoPlayablePath,
    /// ⭐ 本文件新增的那一类:服务端给了一条**本机放不了**的 DirectStream,
    /// 却没有给 `TranscodingUrl`。这正是第 4 节描述的静默失败 ——
    /// 照旧实现会黑屏,这里选择报错。
    ServerOfferedUnplayableDirectStream {
        actions: Vec<ServerAction>,
        notes: Vec<String>,
    },
}

impl PlaybackError {
    /// 给用户看的文案(与 Swift 侧 `PlaybackError.userMessage` 同一口径)
    pub fn user_message(&self) -> String {
        match self {
            Self::ServerRejected { code } => format!("服务器拒绝播放(错误码 {code})。"),
            Self::NoMediaSource => "服务器没有返回任何可播放的媒体源。".to_string(),
            Self::MissingRequiredField { name } => {
                format!("服务器返回的播放信息缺少必需字段 {name}。")
            }
            Self::NoPlayablePath => {
                "这台服务器对该文件既不支持直接串流,也没有给出转码地址。".to_string()
            }
            Self::ServerOfferedUnplayableDirectStream { actions, .. } => {
                let needs: Vec<&str> = actions.iter().map(|a| a.label()).collect();
                format!(
                    "服务器给的直连流本机放不了(需要服务端:{}),而它没有提供转码地址。",
                    needs.join("、")
                )
            }
        }
    }
}

/// 执行决策。签名与 `PlaybackDecisionEngine.session` 对应,但把
/// 「本机能力表」显式作为输入 —— 决策结果必须是能力表的函数,不是隐式的。
pub fn decide(
    response: &PlaybackInfoResponse,
    capabilities: &AvkitCapabilities,
) -> Result<PlaybackDecision, PlaybackError> {
    // 1. ErrorCode 非空 → 服务端拒绝播放
    if let Some(code) = response.error_code.as_deref().filter(|c| !c.is_empty()) {
        return Err(PlaybackError::ServerRejected {
            code: code.to_string(),
        });
    }

    // 2. MediaSources 为空(或缺失)→ 没有可播源
    let sources = match response.media_sources.as_deref() {
        Some(s) if !s.is_empty() => s,
        _ => return Err(PlaybackError::NoMediaSource),
    };

    // 3. PlaySessionId:4.5 把它列为串流 URL 的必填参数,后续停止/上报也靠它。
    //    缺了不能靠猜,也不能拿空串顶替(8.1 禁止填假默认值)。
    let play_session_id = response
        .play_session_id
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| PlaybackError::MissingRequiredField {
            name: "PlaySessionId".to_string(),
        })?;

    // 4. 选定 MediaSource:多个时取第一个支持 DirectStream 的,都不支持则取第一个(4.4 第 3 步)
    let selected = sources
        .iter()
        .find(|s| s.supports_direct_stream == Some(true))
        .unwrap_or(&sources[0]);

    // 4.5. 用本机能力表复核(见模块文档)
    let audit = capabilities.audit(selected);
    let path_actions = audit.path_actions();

    let has_direct_stream = selected.supports_direct_stream == Some(true)
        || selected.direct_stream_url.as_deref().is_some_and(|u| !u.is_empty());
    let transcoding_url = selected
        .transcoding_url
        .as_deref()
        .filter(|u| !u.is_empty())
        .map(str::to_string);

    let method = if path_actions.is_empty() {
        // 客户端能原样放。优先 DirectStream;服务端若另有安排(如按码率限制
        // 主动要求转码),也能接受转码地址。
        if has_direct_stream {
            PlaybackMethod::DirectStream
        } else if transcoding_url.is_some() {
            PlaybackMethod::Transcode
        } else {
            // 5/6. 都没有 → 报错。⛔ 不得自己拼一个「猜的」URL 去试。
            return Err(PlaybackError::NoPlayablePath);
        }
    } else if transcoding_url.is_some() {
        // 服务端必须做点事,且给了入口 → 转码(重封装 / 转音频 / 烧字幕)
        PlaybackMethod::Transcode
    } else {
        // 服务端什么介入都没做,却给了直连流 —— 这就是静默失败本身。
        return Err(PlaybackError::ServerOfferedUnplayableDirectStream {
            actions: path_actions,
            notes: audit.notes.clone(),
        });
    };

    Ok(PlaybackDecision {
        method,
        audit,
        media_source_id: selected.id.clone(),
        play_session_id: play_session_id.to_string(),
        direct_stream_url: selected.direct_stream_url.clone(),
        transcoding_url,
        transcoding_sub_protocol: selected.transcoding_sub_protocol.clone(),
        capability_revision: capabilities.revision.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(json: &str) -> PlaybackInfoResponse {
        serde_json::from_str(json).expect("测试用响应应能解码")
    }

    fn decide_json(json: &str) -> Result<PlaybackDecision, PlaybackError> {
        decide(&parsed(json), &AvkitCapabilities::current())
    }

    #[test]
    fn rejects_when_server_says_error_code() {
        let err = decide_json(r#"{"ErrorCode":"NoCompatibleStream"}"#).unwrap_err();
        assert_eq!(
            err,
            PlaybackError::ServerRejected {
                code: "NoCompatibleStream".to_string()
            }
        );
    }

    #[test]
    fn rejects_when_no_media_source() {
        assert_eq!(
            decide_json(r#"{"PlaySessionId":"ps"}"#).unwrap_err(),
            PlaybackError::NoMediaSource
        );
        assert_eq!(
            decide_json(r#"{"PlaySessionId":"ps","MediaSources":[]}"#).unwrap_err(),
            PlaybackError::NoMediaSource
        );
    }

    /// 空串 `PlaySessionId` 与缺失同等对待 —— ⛔ 不许拿空串顶替(8.1)。
    #[test]
    fn rejects_when_play_session_id_missing_or_blank() {
        let body = r#"{"MediaSources":[{"Id":"s","Container":"mp4",
            "MediaStreams":[{"Type":"Video","Codec":"h264"},{"Type":"Audio","Codec":"aac"}]}]}"#;
        assert_eq!(
            decide_json(body).unwrap_err(),
            PlaybackError::MissingRequiredField {
                name: "PlaySessionId".to_string()
            }
        );
        let blank = body.replace(
            "\"MediaSources\"",
            "\"PlaySessionId\":\"\",\"MediaSources\"",
        );
        assert_eq!(
            decide_json(&blank).unwrap_err(),
            PlaybackError::MissingRequiredField {
                name: "PlaySessionId".to_string()
            }
        );
    }

    #[test]
    fn native_source_with_direct_stream_url_is_direct_stream() {
        let decision = decide_json(
            r#"{
                "PlaySessionId": "ps-1",
                "MediaSources": [{
                    "Id": "src-1", "Container": "mp4",
                    "SupportsDirectStream": true,
                    "DirectStreamUrl": "/videos/1/original.mp4?api_key=FAKE",
                    "MediaStreams": [
                        {"Index":0,"Type":"Video","Codec":"h264"},
                        {"Index":1,"Type":"Audio","Codec":"aac"}
                    ]
                }]
            }"#,
        )
        .expect("应给出 DirectStream");

        assert_eq!(decision.method, PlaybackMethod::DirectStream);
        assert_eq!(decision.media_source_id, "src-1");
        assert_eq!(decision.play_session_id, "ps-1");
        assert!(decision.transcoding_url.is_none());
        assert!(decision.capability_revision.contains("avkit-capability"));
    }

    /// ⭐ 静默失败守卫:服务端说能直连,但本机放不了 MKV,且没给转码地址。
    #[test]
    fn unplayable_direct_stream_without_transcode_url_is_an_error() {
        let err = decide_json(
            r#"{
                "PlaySessionId": "ps-1",
                "MediaSources": [{
                    "Id": "src-1", "Container": "mkv",
                    "SupportsDirectStream": true,
                    "DirectStreamUrl": "/videos/1/original.mkv",
                    "MediaStreams": [
                        {"Index":0,"Type":"Video","Codec":"h264"},
                        {"Index":1,"Type":"Audio","Codec":"aac"}
                    ]
                }]
            }"#,
        )
        .unwrap_err();

        match err {
            PlaybackError::ServerOfferedUnplayableDirectStream { actions, notes } => {
                assert_eq!(actions, vec![ServerAction::RemuxContainer]);
                assert!(!notes.is_empty(), "必须带上可读理由");
            }
            other => panic!("应是静默失败守卫,实际 {other:?}"),
        }
    }

    #[test]
    fn unplayable_source_with_transcode_url_becomes_transcode() {
        let decision = decide_json(
            r#"{
                "PlaySessionId": "ps-1",
                "MediaSources": [{
                    "Id": "src-1", "Container": "mkv",
                    "SupportsDirectStream": false,
                    "TranscodingUrl": "/emby/videos/1/master.m3u8?api_key=FAKE",
                    "TranscodingSubProtocol": "hls",
                    "MediaStreams": [
                        {"Index":0,"Type":"Video","Codec":"h264"},
                        {"Index":1,"Type":"Audio","Codec":"dts"}
                    ]
                }]
            }"#,
        )
        .expect("应给出转码");

        assert_eq!(decision.method, PlaybackMethod::Transcode);
        assert_eq!(
            decision.audit.path_actions(),
            vec![ServerAction::RemuxContainer, ServerAction::TranscodeAudio]
        );
        assert_eq!(
            decision.transcoding_url.as_deref(),
            Some("/emby/videos/1/master.m3u8?api_key=FAKE")
        );
    }

    #[test]
    fn neither_direct_stream_nor_transcode_is_no_playable_path() {
        assert_eq!(
            decide_json(
                r#"{
                    "PlaySessionId": "ps-1",
                    "MediaSources": [{
                        "Id": "src-1", "Container": "mp4",
                        "MediaStreams": [
                            {"Index":0,"Type":"Video","Codec":"h264"},
                            {"Index":1,"Type":"Audio","Codec":"aac"}
                        ]
                    }]
                }"#
            )
            .unwrap_err(),
            PlaybackError::NoPlayablePath
        );
    }

    /// 多源:取第一个支持 DirectStream 的(4.4 第 3 步)。
    #[test]
    fn picks_first_source_supporting_direct_stream() {
        let decision = decide_json(
            r#"{
                "PlaySessionId": "ps-1",
                "MediaSources": [
                    {"Id": "src-transcode-only", "Container": "mp4",
                     "SupportsDirectStream": false,
                     "TranscodingUrl": "/emby/videos/1/master.m3u8",
                     "MediaStreams": [
                        {"Type":"Video","Codec":"h264"},{"Type":"Audio","Codec":"aac"}]},
                    {"Id": "src-direct", "Container": "mp4",
                     "SupportsDirectStream": true,
                     "DirectStreamUrl": "/videos/1/original.mp4",
                     "MediaStreams": [
                        {"Type":"Video","Codec":"h264"},{"Type":"Audio","Codec":"aac"}]}
                ]
            }"#,
        )
        .expect("决策");

        assert_eq!(decision.media_source_id, "src-direct");
        assert_eq!(decision.method, PlaybackMethod::DirectStream);
    }

    /// `MediaStreams` 缺失时视频/音频判不了。此时**不**凭空要求转码 ——
    /// 没有凭据的动作会误伤本来能直连的源;`unverifiable_dimensions` 负责
    /// 把「这次没核实」暴露给上层,而不是默默当成没问题。
    #[test]
    fn unverifiable_dimensions_do_not_force_transcode_but_are_reported() {
        let decision = decide_json(
            r#"{
                "PlaySessionId": "ps-1",
                "MediaSources": [{
                    "Id": "src-1", "Container": "mp4",
                    "SupportsDirectStream": true,
                    "DirectStreamUrl": "/videos/1/original.mp4"
                }]
            }"#,
        )
        .expect("决策");

        assert_eq!(decision.method, PlaybackMethod::DirectStream);
        assert_eq!(
            decision.audit.unverifiable_dimensions(),
            vec!["视频", "音频", "字幕"]
        );
    }

    #[test]
    fn error_messages_are_explainable() {
        assert!(PlaybackError::NoMediaSource
            .user_message()
            .contains("可播放的媒体源"));
        let err = PlaybackError::ServerOfferedUnplayableDirectStream {
            actions: vec![ServerAction::RemuxContainer],
            notes: vec!["容器 mkv 不是 AVKit 原生支持".to_string()],
        };
        assert!(err.user_message().contains("重封装容器"));
    }
}
