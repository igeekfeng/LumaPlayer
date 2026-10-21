import Foundation

/// `sub-add` 的 flags 取值(`Vendor/mpv/src/DOCS/man/input.rst:658`)。
///
/// - `select`:加载后**立刻选中**这条字幕 —— 命令的默认行为;
/// - `auto`:不选中,交给 mpv 的默认轨选择(已经有用户选过的轨时不抢)。
///
/// 口径:手动加载 / 在线下载的字幕用 `select`(用户点这一下就是要看它);
/// 百度同目录的自动字幕用 `auto`(只是「有就用上」,⛔ 不该盖掉用户的选择)。
enum SubtitleAddFlag: String, Sendable {
    case select
    case auto
}
