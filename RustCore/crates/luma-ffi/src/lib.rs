//! UniFFI 接口层 —— Rust 核心**唯一**对外暴露的面。
//!
//! 设计原则(见 `docs/DECISIONS/avkit-rust-rearchitecture.md` 5.3):
//! - 只暴露**命令 + 事件流**;⛔ 不把 Rust 内部数据结构树原样映射出去;
//! - ⛔ 视频帧 / 大 buffer **绝不**跨语言序列化。本分支播放层在 Swift,不涉及;
//!   若将来把解码也搬进 Rust,必须走「宿主提供渲染表面」或零拷贝共享 buffer。
//!
//! **现状:P1 骨架。** 目前暴露的都是连通性自检用的函数,不是产品接口。
//!
//! ⚠️ 本 crate 是 workspace 里唯一**没有** `#![forbid(unsafe_code)]` 的 ——
//! `uniffi::setup_scaffolding!()` 会生成含 `unsafe` 的胶水代码。
//! 其余四个 crate 都加了这条 forbid。

uniffi::setup_scaffolding!("luma_core");

use luma_emby::ClientIdentity;

/// Rust 核心的版本,以及它实现所依据的接口契约修订。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreInfo {
    /// `luma-ffi` 的 Cargo 版本。
    pub version: String,
    /// 本核心实现所依据的 `docs/API_CONTRACT.md` 修订。
    pub api_contract: String,
}

/// P1 连通性自检:返回核心信息。
///
/// 存在的意义是让 Swift 侧有一条**能证伪**的调用 —— 光是 `build` 通过证明不了
/// FFI 边界是通的(`DECISIONS/avkit-rust-rearchitecture.md` P1 门禁要求
/// 「一个 hello 函数能从 Swift 调到」)。结构化返回类型同时证明 `Record` 能过边界。
#[uniffi::export]
pub fn core_info() -> CoreInfo {
    CoreInfo {
        version: env!("CARGO_PKG_VERSION").to_string(),
        api_contract: "API_CONTRACT.md (2026-09-29)".to_string(),
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
