//! 打印本分支该发的 `DeviceProfile` JSON。
//!
//! 用途只有一个:**喂给 `Tools/emby-dev/` 的抓取脚本**,让它用「Rust 真正会发的
//! 那一份 profile」去请求 `PlaybackInfo`,抓回来的响应才能当 fixture 用。
//! 手写一份等价 JSON 去抓是错的 —— 一旦两份漂移,fixture 就不再代表真实行为。
//!
//! ```bash
//! cd RustCore && cargo run -p luma-ffi --example device_profile
//! ```

fn main() {
    println!("{}", luma_core::avkit_device_profile_json());
}
