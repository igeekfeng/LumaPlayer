//! UniFFI 接口层 —— Rust 核心**唯一**对外暴露的面。
//!
//! 设计原则(见 `docs/DECISIONS/avkit-rust-rearchitecture.md` 5.3):
//! - 只暴露**命令 + 事件流**;⛔ 不把 Rust 内部数据结构树原样映射出去;
//! - ⛔ 视频帧 / 大 buffer **绝不**跨语言序列化。本分支播放层在 Swift,不涉及;
//!   若将来把解码也搬进 Rust,必须走「宿主提供渲染表面」或零拷贝共享 buffer。
//!
//! 现状(P2,2026-10-10):暴露 DeviceProfile 与播放决策两组命令。
//! 决策的**全部逻辑**在 `luma-emby` 里,这里只做翻译与过边界。
//!
//! ⚠️ 本 crate 是 workspace 里唯一**没有** `#![forbid(unsafe_code)]` 的 ——
//! `uniffi::setup_scaffolding!()` 会生成含 `unsafe` 的胶水代码。
//! 其余四个 crate 都加了这条 forbid。

uniffi::setup_scaffolding!("luma_core");

use luma_emby::{
    AvkitCapabilities, ClientIdentity, DeviceProfile, PlaybackError, PlaybackInfoResponse,
};

/// Rust 核心的版本,以及它实现所依据的接口契约修订。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreInfo {
    /// `luma-ffi` 的 Cargo 版本。
    pub version: String,
    /// 本核心实现所依据的 `docs/API_CONTRACT.md` 修订。
    pub api_contract: String,
    /// 本核心所依据的 AVKit 能力表版本。
    /// ⚠️ 表还是 🔶 二手来源(未在本机 AVPlayer 实测),P3 实测后这里会变。
    pub capability_revision: String,
}

/// P1 连通性自检:返回核心信息。
#[uniffi::export]
pub fn core_info() -> CoreInfo {
    CoreInfo {
        version: env!("CARGO_PKG_VERSION").to_string(),
        api_contract: "API_CONTRACT.md (2026-09-29)".to_string(),
        capability_revision: AvkitCapabilities::current().revision.to_string(),
    }
}

/// 最小往返:证明 `String` 双向过边界。
#[uniffi::export]
pub fn echo(message: String) -> String {
    message
}

/// 跨 crate 连通性证明:`luma-ffi → luma-emby` 的依赖真的链上了。
///
/// 返回 Emby `Authorization` 头的值。逻辑本身在 `luma-emby` 里有单测,
/// 这里只负责过边界。
#[uniffi::export]
pub fn emby_authorization_header(
    device: String,
    device_id: String,
    version: String,
    user_id: Option<String>,
) -> String {
    ClientIdentity::new(&device, &device_id, &version)
        .authorization_header(user_id.as_deref())
}

/// AVKit 目标 `DeviceProfile` 的 JSON。
///
/// Swift 侧直接把它塞进 `PlaybackInfo` 请求体的 `DeviceProfile` 键 ——
/// 白名单只有一份,在 Rust 里由能力表派生(见 `luma-emby::device_profile`)。
/// ⛔ 不要在 Swift 里另写一份白名单,两份一旦漂移就是静默失败。
#[uniffi::export]
pub fn avkit_device_profile_json() -> String {
    serde_json::to_string(&DeviceProfile::avkit())
        .expect("DeviceProfile 是纯数据结构,序列化不会失败")
}

/// 逐维度判定结果(`luma-emby::PlaybackAudit` 的过边界形态)。
///
/// 各字段都已经是给人看的字符串 —— 决策的**结构性**结论
/// (`method` / URL)在 [`PlaybackDecisionFfi`] 上,这里只补解释。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlaybackAuditFfi {
    /// 决定播放路径的服务端动作(容器 / 视频 / 音频三维),如 `["重封装容器"]`
    pub path_actions: Vec<String>,
    /// 字幕维所需的处理;不需要时为 `None`
    pub subtitle_action: Option<String>,
    /// 判不了的维度名(如响应里缺 `MediaStreams`)。
    /// ⚠️ 非空表示**这次没有核实过**,不是「核实过没问题」。
    pub unverifiable_dimensions: Vec<String>,
    /// 非原生维度的可读理由
    pub notes: Vec<String>,
}

/// 播放决策结果。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlaybackDecisionFfi {
    /// `DirectStream` / `Transcode` —— 直接用作上报的 `PlayMethod`
    pub method: String,
    /// UI 上显示的名字(中文)
    pub method_display_name: String,
    pub media_source_id: String,
    pub play_session_id: String,
    /// 服务端给的直连地址(相对 API 根,带 `api_key`)。取用时剥掉 `api_key`。
    pub direct_stream_url: Option<String>,
    /// 服务端给的转码地址(相对路径)。**唯一**合法的转码入口。
    pub transcoding_url: Option<String>,
    pub transcoding_sub_protocol: Option<String>,
    pub audit: PlaybackAuditFfi,
    pub capability_revision: String,
}

/// 决策失败。
///
/// 每个变体都自带 **`message`(可解释的中文文案)**,另按需要带结构化字段
/// (错误码 / 缺的字段名 / 需要服务端做哪几件事)。文案由 Rust 侧
/// `PlaybackError::user_message` 生成,⛔ Swift 不重新拼一份 ——
/// 两份文案漂移的结果是「日志说是 A,界面显示说 B」。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Error)]
pub enum PlaybackFailureFfi {
    /// 服务端明确拒绝(响应里 `ErrorCode` 非空)
    ServerRejected { code: String, message: String },
    /// 响应里没有任何 MediaSource
    NoMediaSource { message: String },
    /// 响应缺少构造播放所必需的字段
    MissingRequiredField { name: String, message: String },
    /// 既不能 DirectStream,也没有 `TranscodingUrl`
    NoPlayablePath { message: String },
    /// 服务端给了本机放不了的直连流,却又不给转码地址(第 4 节的静默失败)
    UnplayableDirectStream {
        path_actions: Vec<String>,
        notes: Vec<String>,
        message: String,
    },
}

impl std::fmt::Display for PlaybackFailureFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = match self {
            Self::ServerRejected { message, .. }
            | Self::NoMediaSource { message }
            | Self::MissingRequiredField { message, .. }
            | Self::NoPlayablePath { message }
            | Self::UnplayableDirectStream { message, .. } => message,
        };
        f.write_str(message)
    }
}

impl std::error::Error for PlaybackFailureFfi {}

impl From<PlaybackError> for PlaybackFailureFfi {
    fn from(error: PlaybackError) -> Self {
        let message = error.user_message();
        match error {
            PlaybackError::ServerRejected { code } => Self::ServerRejected { code, message },
            PlaybackError::NoMediaSource => Self::NoMediaSource { message },
            PlaybackError::MissingRequiredField { name } => {
                Self::MissingRequiredField { name, message }
            }
            PlaybackError::NoPlayablePath => Self::NoPlayablePath { message },
            PlaybackError::ServerOfferedUnplayableDirectStream { actions, notes } => {
                Self::UnplayableDirectStream {
                    path_actions: actions.iter().map(|a| a.label().to_string()).collect(),
                    notes,
                    message,
                }
            }
        }
    }
}

/// 播放决策。输入是 `PlaybackInfo` 响应的**原始 JSON**(Swift 侧拿到什么就传什么),
/// 输出是逐维度的决策结果。
///
/// 把「响应解析」也放在边界内,是为了让 Swift 不必再维护一份字段映射 ——
/// 字段名只有 `luma-emby::models` 一份。
///
/// ⚠️ 响应 JSON 解不开时归到 `NoMediaSource`:对调用方而言「解析不出可播源」
/// 与「服务端没给可播源」要做的处置是同一件事(报错并提示服务器异常)。
#[uniffi::export]
pub fn decide_playback(
    playback_info_json: String,
) -> Result<PlaybackDecisionFfi, PlaybackFailureFfi> {
    let response: PlaybackInfoResponse =
        serde_json::from_str(&playback_info_json).map_err(|error| {
            PlaybackFailureFfi::NoMediaSource {
                message: format!("PlaybackInfo 响应无法解析:{error}"),
            }
        })?;

    let decision = luma_emby::decision::decide(&response, &AvkitCapabilities::current())?;

    Ok(PlaybackDecisionFfi {
        method: decision.method.wire_name().to_string(),
        method_display_name: decision.method.display_name().to_string(),
        media_source_id: decision.media_source_id,
        play_session_id: decision.play_session_id,
        direct_stream_url: decision.direct_stream_url,
        transcoding_url: decision.transcoding_url,
        transcoding_sub_protocol: decision.transcoding_sub_protocol,
        audit: PlaybackAuditFfi {
            path_actions: decision
                .audit
                .path_actions()
                .iter()
                .map(|a| a.label().to_string())
                .collect(),
            subtitle_action: decision.audit.subtitle_action().map(|a| a.label().to_string()),
            unverifiable_dimensions: decision
                .audit
                .unverifiable_dimensions()
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            notes: decision.audit.notes.clone(),
        },
        capability_revision: decision.capability_revision,
    })
}
