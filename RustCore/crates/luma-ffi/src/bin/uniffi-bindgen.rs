//! UniFFI 绑定生成器的入口。
//!
//! 放在 workspace 里、而不是 `cargo install uniffi-bindgen`,是为了让生成器的版本
//! 与 `luma-ffi` 依赖的 `uniffi` 版本**永远锁在一起** ——
//! 两者版本不一致会生成对不上的绑定,而且报错信息很难看出是这个原因。

fn main() {
    uniffi::uniffi_bindgen_main()
}
