#![forbid(unsafe_code)]

//! SQLite 媒体库:播放进度、收藏、本地索引、接口响应缓存。
//!
//! **现状:P1 骨架。** 见 `docs/DECISIONS/avkit-rust-rearchitecture.md` 第 6 节与 P4 阶段。
//!
//! 两条必须迁过来的既有约定(`docs/DECISIONS/local-cache.md`,⛔ 不能丢):
//! 1. 接口缓存的 key **含 serverID、不含 host** —— 同一台服务器换地址(Host / 局域网 IP)
//!    之后缓存仍然有效;
//! 2. 写操作、开始 / 停止播放、登录 / 登出时,**整台服务器**的缓存作废(epoch 机制)。

/// 库文件的 schema 版本。
///
/// ⛔ 改 schema 必须同时改这个数字并写迁移,不允许「删库重来」——
/// 里面有播放进度与收藏,删了不可恢复。
pub const SCHEMA_VERSION: u32 = 1;
