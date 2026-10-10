#![forbid(unsafe_code)]

//! 多源接入:WebDAV / SMB / 网盘。
//!
//! **现状:P1 骨架,只有类型定义。** 见 `docs/DECISIONS/avkit-rust-rearchitecture.md`
//! 5.2 节与 P5 阶段。
//!
//! ⚠️ **SMB 这一条还没定**:macOS 上更现实的做法是走系统的 `mount_smbfs` / `smb://` URL,
//! Rust 纯 SMB(SMB3)客户端生态弱。若最终决定走系统挂载,
//! **这一层就不该由 Rust 承担** —— 所以先不要在这里写 SMB 实现,
//! 等 P5 阶段用真实服务器实测过再定。

/// 媒体来源的种类。
///
/// 播放层只关心一件事:这个来源能不能给出一个 `AVPlayer` 放得了的 URL。
/// 各来源自己的协议细节**不越过 UniFFI 边界**。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    /// Emby / Jellyfin 服务器。走 `luma-emby`,不在这里实现。
    Emby,
    WebDav,
    /// ⚠️ 待定,见本模块文档。
    Smb,
    /// 各家网盘私有 API。每家一个,不存在统一抽象。
    CloudDrive,
}

impl SourceKind {
    /// 该来源是否需要客户端自己拼 URL 交给播放层。
    ///
    /// Emby 的 URL 由服务端 `PlaybackInfo` 决定,⛔ 客户端不许自己拼
    /// (`API_CONTRACT.md` 4.4);其余来源要给一个可直接播放的 URL。
    pub fn client_builds_url(self) -> bool {
        !matches!(self, SourceKind::Emby)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_non_emby_sources_build_urls_client_side() {
        assert!(!SourceKind::Emby.client_builds_url());
        assert!(SourceKind::WebDav.client_builds_url());
        assert!(SourceKind::Smb.client_builds_url());
        assert!(SourceKind::CloudDrive.client_builds_url());
    }
}
