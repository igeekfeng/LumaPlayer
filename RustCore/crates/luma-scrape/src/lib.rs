#![forbid(unsafe_code)]

//! 媒体库元数据刮削(标题、年份、海报、演职人员)。
//!
//! **现状:P1 骨架,只有类型定义。** 见
//! `docs/DECISIONS/avkit-rust-rearchitecture.md` 5.2 节与 P5 阶段。
//!
//! ⛔ 刮削结果只写本地 `luma-store`,**不写回服务器** ——
//! 服务器不都是自己的,写操作是 `CLAUDE.md` 明令禁止的。

/// 一次刮削的输入。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrapeQuery {
    /// 原始文件名或服务端给的标题。
    pub title: String,
    /// 已知年份。有年份时匹配精度会高很多,但**不能**因为缺年份就拒绝刮削。
    pub year: Option<u16>,
}

impl ScrapeQuery {
    pub fn new(title: impl Into<String>, year: Option<u16>) -> Self {
        Self {
            title: title.into(),
            year,
        }
    }
}
