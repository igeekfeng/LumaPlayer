//! 客户端身份与 Emby 认证头。
//!
//! 这一块在 P1 就落成真代码了,因为它是 `CLAUDE.md` 点名的**最高频失败原因**:
//! token 走 `Authorization` 头而不是独立的 `X-Emby-Token`,`UserId` 缺了写成空串
//! —— 这两种错都会表现为「服务端当成另一个身份/另一个客户端」,极难排查。

/// `Authorization` 头的认证方案前缀。
const AUTH_SCHEME: &str = "Emby";

/// 客户端对服务端的自我描述,对应 `API_CONTRACT.md` 第 2 节。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientIdentity {
    pub client: String,
    pub device: String,
    pub device_id: String,
    pub version: String,
}

impl ClientIdentity {
    /// `device` 传本机 host,构造时就会过一遍 [`sanitize_device`]。
    pub fn new(device: &str, device_id: &str, version: &str) -> Self {
        Self {
            client: "LumaPlayer".to_string(),
            device: sanitize_device(device),
            device_id: device_id.to_string(),
            version: version.to_string(),
        }
    }

    /// 构造 `Authorization` 头的值。
    ///
    /// `user_id` 为 `None` 时**省略整段 `UserId="…"`**,⛔ 不写成空字符串 ——
    /// 空 `UserId` 会被服务端当成另一个身份,是已文档化的失败模式。
    pub fn authorization_header(&self, user_id: Option<&str>) -> String {
        let mut parts: Vec<String> = Vec::with_capacity(5);
        if let Some(uid) = user_id {
            parts.push(format!("UserId=\"{uid}\""));
        }
        parts.push(format!("Client=\"{}\"", self.client));
        parts.push(format!("Device=\"{}\"", self.device));
        parts.push(format!("DeviceId=\"{}\"", self.device_id));
        parts.push(format!("Version=\"{}\"", self.version));
        format!("{} {}", AUTH_SCHEME, parts.join(", "))
    }

    /// 认证 token 走**独立**的头,不拼进 `Authorization`。
    ///
    /// 返回 `(头名, 头值)`,让调用方没法漏掉头名。
    pub fn token_header(token: &str) -> (&'static str, &str) {
        ("X-Emby-Token", token)
    }
}

/// 本机 host 含非 ASCII、或为空时,回退为 `Mac`。
///
/// `Device` 会原样进认证头,非 ASCII 会让部分服务器直接返回 400。
/// 宁可丢一点信息,也不发一个畸形的头出去。
pub fn sanitize_device(raw: &str) -> String {
    if !raw.is_empty() && raw.is_ascii() {
        raw.to_string()
    } else {
        "Mac".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEVICE_ID: &str = "0123456789abcdef";

    #[test]
    fn logged_out_omits_user_id_entirely() {
        let id = ClientIdentity::new("192.168.1.10", DEVICE_ID, "0.1.0");
        let header = id.authorization_header(None);

        assert!(
            !header.contains("UserId"),
            "未登录时不允许出现 UserId 段,实际:{header}"
        );
        assert_eq!(
            header,
            "Emby Client=\"LumaPlayer\", Device=\"192.168.1.10\", \
             DeviceId=\"0123456789abcdef\", Version=\"0.1.0\""
        );
    }

    #[test]
    fn logged_in_puts_user_id_first() {
        let id = ClientIdentity::new("192.168.1.10", DEVICE_ID, "0.1.0");
        let header = id.authorization_header(Some("user-42"));

        assert_eq!(
            header,
            "Emby UserId=\"user-42\", Client=\"LumaPlayer\", Device=\"192.168.1.10\", \
             DeviceId=\"0123456789abcdef\", Version=\"0.1.0\""
        );
    }

    #[test]
    fn token_never_goes_into_authorization_header() {
        let id = ClientIdentity::new("192.168.1.10", DEVICE_ID, "0.1.0");
        let header = id.authorization_header(Some("user-42"));

        assert!(!header.contains("Token"));
        assert!(!header.contains("X-Emby-Authorization"));
        assert_eq!(ClientIdentity::token_header("abc"), ("X-Emby-Token", "abc"));
    }

    #[test]
    fn ascii_device_passes_through() {
        assert_eq!(sanitize_device("192.168.1.10"), "192.168.1.10");
        assert_eq!(sanitize_device("MacBook-Pro"), "MacBook-Pro");
    }

    #[test]
    fn non_ascii_or_empty_device_falls_back_to_mac() {
        assert_eq!(sanitize_device("峰哥的-Mac"), "Mac");
        assert_eq!(sanitize_device(""), "Mac");
        assert_eq!(sanitize_device("Mac-🙂"), "Mac");
    }
}
