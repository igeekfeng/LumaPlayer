#![forbid(unsafe_code)]

//! Emby / Jellyfin API 客户端、`DeviceProfile` 与播放决策。
//!
//! 完整搬移计划见 `docs/DECISIONS/avkit-rust-rearchitecture.md` 第 4、5 节。
//!
//! 现状(P2,2026-10-10):已落地
//! - [`identity`]:客户端身份与认证头(P1 就有的真代码)
//! - [`models`]:`PlaybackInfo` 的请求体与响应体
//! - [`capability`]:AVKit 兼容性表(🔶 未在本机实测,见该模块文档)
//! - [`device_profile`]:从能力表派生的 `DeviceProfile`
//! - [`decision`]:决策器(P2 的核心)
//!
//! 还没搬的:HTTP 传输层、多源接入、刮削、SQLite(见第 8 节 P4/P5)。
//!
//! 纪律(与 `docs/API_CONTRACT.md` 一致,搬移后仍然适用):
//! - ⛔ **不发明端点**:只用 `API_CONTRACT.md` 里标 ✅ 或 🔶 的端点 / 参数 / 字段名。
//!   遇到 ⚠️ 或文档里没有的,先核实再回填文档,别猜。
//! - 认证头必须是 Emby 风格:token 走**独立的** `X-Emby-Token` 头,
//!   ⛔ 不用 Jellyfin 的 `X-Emby-Authorization: MediaBrowser …`。

pub mod capability;
pub mod decision;
pub mod device_profile;
pub mod identity;
pub mod models;

pub use capability::{AvkitCapabilities, Dimension, PlaybackAudit, ServerAction};
pub use decision::{PlaybackDecision, PlaybackError, PlaybackMethod};
pub use device_profile::DeviceProfile;
pub use identity::{sanitize_device, ClientIdentity};
pub use models::{MediaSource, MediaStream, PlaybackInfoRequest, PlaybackInfoResponse};
