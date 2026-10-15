# LumaPlayer

![Platform](https://img.shields.io/badge/platform-macOS%2027%2B%20%7C%20arm64-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Signing](https://img.shields.io/badge/signing-ad--hoc%20%7C%20not%20notarized-yellow)

macOS 原生 Emby 客户端。SwiftUI 写界面，自编 libmpv（gpu-next）负责解码播放，直接对接你自己（或朋友的）Emby 服务器；百度网盘也可以作为播放来源接入。

> **平台限制**：仅支持 **macOS 27+ / Apple Silicon（arm64）**。不提供 Intel 与 Universal 构建，代码里也没有 `#available` 守卫 —— 这是刻意的取舍：libmpv 及其依赖也是按 27.0 编译的，部署目标更低会有链接器 warning 且产物跑不起来。

## 目录

- [特性](#特性)
- [环境要求](#环境要求)
- [构建](#构建)
- [打包与安装](#打包与安装)
- [使用](#使用)
- [项目结构](#项目结构)
- [开发](#开发)
- [已知限制](#已知限制)
- [致谢](#致谢)
- [许可证](#许可证)

## 特性

- **多来源**：Emby 服务器与百度网盘都是「播放来源」，在添加时选类型。每台服务器 / 每个网盘来源各自独立的连接、token 与缓存，互不串台
- **播放**：DirectStream / 转码两条路径由服务端 `PlaybackInfo` 决定；转码 seek 走停流 + `StartTimeTicks` 重新起流
- **浏览**：首页（随机推荐轮播 / 继续观看 / 下一集 / 分库最新）、媒体库（排序、筛选、已看角标、右键操作）、搜索、详情、剧集页
- **播放控制**：独立播放窗口、自动隐藏控制栏、0.25–4× 连续倍速、字幕轨默认选简中（其次繁中）
- **弹幕**：接入弹弹play，Emby 与百度网盘两路来源都支持；AppId / AppSecret 由用户自填
- **元数据刮削**：百度网盘不提供封面、简介、年份与剧集结构，用 TMDB 补齐
- **进度上报**：按 actor 串行化并带代次号，切媒体 / 切服务器时丢弃旧结果
- **安全**：token 存沙盒容器内的凭据文件（0600、不进备份），密码不落盘

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | macOS 27 或更高 |
| 芯片 | Apple Silicon（arm64） |
| Xcode | 16 或更高（工程用同步文件夹，`objectVersion = 77`；开发实测 Xcode 27） |
| Swift | 6 语言模式（`SWIFT_VERSION = 6.0`） |
| 构建 libmpv 额外依赖 | `meson`、`ninja`、`pkgconf` |

## 构建

libmpv **不在仓库里**，新克隆必须先自己编一份（约几百 MB 产物，产物目录已 gitignore）：

```bash
brew install meson ninja pkgconf
./Scripts/build-libmpv.sh          # 产物在 Vendor/mpv/prefix/
```

为什么要自编，而不是用 `brew install mpv`：Dolby Vision（Profile 5）片源在老 `gpu` 渲染器上会发紫发绿，只有 `gpu-next`（libplacebo）才处理得对，而它进 render API 依赖一个尚未合并的上游 draft PR。脚本把该 PR 的 commit 钉死，并复用 Homebrew 那份 ffmpeg / libplacebo / libass 等依赖。

编好之后：

```bash
# 构建（要求零编译器 warning）
xcodebuild -scheme LumaPlayer -destination 'platform=macOS,arch=arm64' build

# 全部测试
xcodebuild -scheme LumaPlayer -destination 'platform=macOS,arch=arm64' test

# 单个测试类 / 单个测试
xcodebuild -scheme LumaPlayer -destination 'platform=macOS,arch=arm64' \
  -only-testing:LumaPlayerTests/SmokeTests test
```

判定看**退出码**，不是输出结尾。日志里的
`appintentsmetadataprocessor: ... no AppIntents.framework dependency found` 是信息性输出。

也可以直接用 Xcode 打开 `LumaPlayer.xcodeproj` 跑。

## 打包与安装

```bash
# 安装到本机 /Applications（装完自动启动；加 --no-open 则不启动）
./Scripts/deploy-to-applications.sh          # 加 --no-build 则只拷贝
# 打 DMG（产物在 build/LumaPlayer-{版本}-{构建号}.dmg）
./Scripts/make-dmg.sh
```

两者都会调用 `Scripts/bundle-libmpv.sh`，把 libmpv 及其全部传递依赖打进
`Contents/Frameworks/`，因此装出来的 App 不再依赖目标机的 Homebrew。

App 是 **ad-hoc 签名、未公证**，只适合自己本机使用。

## 使用

1. 首次启动进入引导，先选**来源类型**（Emby 服务器 / 百度网盘）
2. **Emby**：填服务器地址与账号密码，登录后即可浏览
3. **百度网盘**：按提示完成设备码授权，再指定一个目录作为**片库根**（就是浏览页能退到的最外层）
4. 首页 / 媒体库点开条目播放；播放是独立窗口，关窗触发最终进度上报

设置窗口（⌘,）分六页：**通用**（含自定义 User-Agent）、**播放**、**字幕**、**弹幕**、**来源**（增 / 改 / 删 / 授权 / 设片库根）、**已隐藏**。

- 弹幕：需先到弹弹play 开放平台申请 AppId / AppSecret 并在「弹幕」页填入
- 元数据刮削：在「通用」页填 TMDB 的 v4 *API Read Access Token*，留空则不刮削（只写在本机凭据文件里）
- 多服务器切换：窗口工具栏的服务器菜单

## 项目结构

```
LumaPlayer/
├── App/          入口、应用级状态、路由、错误类型
├── Core/         网络（EmbyAPIClient / 端点 / 认证）、服务器连接、安全存储、MPV 封装、
│                 缓存、来源抽象（Emby / 百度网盘）、弹幕、TMDB
├── Features/     Browse / Home / Detail / Library / Player / Search / Servers /
│                 Sources / Settings / Onboarding
├── Models/       Emby 响应模型
├── Components/   设计 token 与复用视图
└── Resources/    Info.plist、entitlements、Assets.xcassets
LumaPlayerTests/  75 个测试文件 + 全部脱敏 fixture
Vendor/           libmpv 的 module map（prefix 需自编，见「构建」）
Tools/            图标生成脚本、本地 Emby 开发实例（Docker）、DV 测试素材工具
Scripts/          构建、打包、部署、隐私自检脚本
```

## 开发

工程用 Xcode 16+ 的**同步文件夹**：往 `LumaPlayer/` 或 `LumaPlayerTests/` 下新增 `.swift`
会自动进编译，**不需要改 `project.pbxproj`**。

测试 fixture 全部为合成数据，不含任何真实服务器地址、用户名或 token；接口行为类结论以实测为准，未在真实服务器验证过的会明确标注。

提交前请确保构建零 warning、测试全绿，并跑一次隐私自检：

```bash
./Scripts/check-privacy.sh
```

## 已知限制

- 仅 macOS 27+ / arm64；ad-hoc 签名、未公证，不提供分发包
- 没有 Direct Play（那是客户端直读文件系统），只有 DirectStream 与转码两条路径
- 非目标：下载 / 离线、直播、音乐、有声书、投屏（Chromecast / DLNA）、客户端自己转码、局域网自动发现服务器
- 未在真实服务器上验证过的行为不会承诺「兼容所有 Emby 实例」


## 致谢

- **mpv / libmpv** —— 播放内核。当前版本从 `gpu-next` render backend 的未合并 draft PR 自编
- **弹弹play 开放平台** —— 弹幕数据来源
- **TMDB** —— 剧集数据来源
- **Emby**
## 许可证

[MIT](LICENSE)
