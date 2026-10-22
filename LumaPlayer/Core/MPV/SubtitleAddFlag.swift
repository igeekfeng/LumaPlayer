import Foundation

/// `sub-add` 的 flags(`Vendor/mpv/src/DOCS/man/input.rst:658`)。
///
/// 手动加载 / 在线下载的用 `select`(立刻选中);百度同目录自动字幕用 `auto`
/// (交给 mpv 默认选轨,⛔ 不盖掉用户的选择)。
enum SubtitleAddFlag: String, Sendable {
    case select
    case auto
}
