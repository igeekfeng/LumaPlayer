# CLAUDE.md

LumaPlayer:自用的 macOS 原生 Emby 播放器(SwiftUI + 自编 libmpv / gpu-next),仅 macOS 27 + Apple Silicon。

细节按需查:`README.md`(命令 / 目录 / 构建 / 打包)、`docs/API_CONTRACT.md`、`docs/MPV_INTEGRATION.md`、
`docs/PITFALLS.md`、`docs/KNOWN_ISSUES.md`。下面只留不易从代码推断的部分。

## 约定

- 注释精简:历史看 git,删掉的东西直接删,不留痕,不复述代码。
- 改动收敛在任务范围内;顺手发现的问题记进 `docs/KNOWN_ISSUES.md` 或单独提。
- `Qnn` / `M2` / `M4` 是问题编号:未结案在 `KNOWN_ISSUES.md`,已结案在 `PITFALLS.md`。
- 提交信息 / PR 引用上游 issue / PR 时,不写成可识别的链接(用「mpv PR 16818」这类形式)。

## 硬规则(其余交给判断)

- 不用 `@unchecked Sendable` / `nonisolated(unsafe)` / `@preconcurrency` / 降回 Swift 5 来消除并发报错。
  唯一例外:`Core/MPV/` 下包裹 C 指针的类型,须注释论证线程安全。
- 不静默吞错、不塞空数组 / 假数据 / `try?` 让上层「看起来能跑」;做不了的分支抛错并登记 `KNOWN_ISSUES.md`。
  缺省值只在 UI 层决定,不进模型层。
- token / 密码不进 `UserDefaults`、日志、诊断文件;日志与错误消息经 `SecretRedactor` 脱敏,且不含带认证参数的完整 URL。
- ad-hoc 签名,凭据不进钥匙串;不要打开 hardened runtime(会让 `MPVPlayer()` 无声退出,Q18)。

## 容易踩的坑(细节见对应文档)

- 播放只有 DirectStream / Transcode 两条路径,由服务端 `PlaybackInfo` 决定,没有 Direct Play;都不满足就抛错,别自己猜 URL(`API_CONTRACT.md` §4)。
- 认证头用独立的 `X-Emby-Token`,不用 Jellyfin 的 `X-Emby-Authorization`;图片统一走 `PosterImage`,禁止裸用 `AsyncImage`(`API_CONTRACT.md` §2)。
- 每台服务器完全隔离(token / 密码 / 缓存各自独立);`DeviceId` 全 App 唯一,删服务器时不删。
- 并发分层、工程约束(手写入库 / 同步文件夹、entitlements、ATS、签名)见 `docs/PITFALLS.md` §1。

## 命令与自检

构建 / 测试 / 打包 / 安装命令见 `README.md`;判定看退出码,构建要求零编译器 warning。
提交前跑 `./Scripts/check-privacy.sh`,并确认没有密钥泄漏、`@unchecked Sendable` 只出现在 `Core/MPV/`。
