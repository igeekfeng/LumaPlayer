# LumaPlayer

一个 macOS 原生 Emby 客户端。SwiftUI 写界面，[Erika](https://github.com/AimesSoft/liberika-swift)（Metal）负责解码播放，直接对接你自己（或朋友的）Emby 服务器。

> **平台限制**：仅支持 **macOS 27+ / Apple Silicon（arm64）**。不提供 Intel 与 Universal 构建，代码里也没有 `#available` 守卫 —— 这是刻意的取舍：部署目标更低会有链接器 warning 且产物跑不起来。

## 特性

- **多服务器**：每台服务器独立的连接、token 与缓存，互不串台；切换在窗口工具栏的服务器菜单，增 / 改 / 删 / 登录在设置窗口（⌘,）的「服务器」标签页
- **播放**：DirectStream / 转码两条路径由服务端 `PlaybackInfo` 决定；转码 seek 走停流 + `StartTimeTicks` 重新起流
- **浏览**：首页（我的媒体 / 继续观看 / 下一集 / 分库最新）、媒体库（排序、筛选、已看角标、右键操作）、搜索、详情、剧集页
- **播放控制**：独立播放窗口、自动隐藏控制栏、0.25–4× 连续倍速、字幕轨默认选简中（其次繁中）
- **进度上报**：按 actor 串行化并带代次号，切媒体 / 切服务器时丢弃旧结果
- **安全**：token 存沙盒容器内的凭据文件（0600、不进备份），密码不落盘

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | macOS 27 或更高 |
| 芯片 | Apple Silicon（arm64） |
| Xcode | 16 或更高（工程用同步文件夹，`objectVersion = 77`） |
| 播放内核 | [liberika-swift](https://github.com/AimesSoft/liberika-swift) 0.3.x（SwiftPM 依赖，构建时自动拉取并静态链接，无需额外安装） |

首次构建（或换机）需要网络：`xcodebuild` 会自动解析 SwiftPM 依赖。也可以先手动解析：

```bash
xcodebuild -resolvePackageDependencies -scheme LumaPlayer
```

## 构建与运行

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

## 打包

```bash
# 安装到本机 /Applications（装完自动启动；加 --no-open 则不启动）
./Scripts/deploy-to-applications.sh          # 加 --no-build 则只拷贝
# 打 DMG（产物在 build/LumaPlayer-{版本}-{构建号}.dmg）
./Scripts/make-dmg.sh
```

播放内核 Erika 由 SwiftPM **静态链接**进 App，DMG / 安装副本自带全部运行时，目标机不需要装任何东西。

App 是 **ad-hoc 签名、未公证**，只适合自己本机使用。

## 工程结构

```
LumaPlayer/
├── App/          入口、应用级状态、错误类型
├── Core/         网络（EmbyAPIClient / 端点 / 认证）、服务器连接、安全存储、播放引擎、缓存
│   ├── Playback/Engine/   内核无关的归一化播放层（协议 + 值类型 + 事件泵）
│   └── Erika/             Erika 适配器（全项目唯一 import 内核的目录）
├── Features/     Browse / Home / Detail / Library / Player / Search / Servers / Settings / Onboarding
├── Models/       Emby 响应模型
├── Components/   设计 token 与复用视图
└── Resources/    Info.plist、entitlements、AppIcon
LumaPlayerTests/  46 个测试文件 + 全部脱敏 fixture
Tools/            图标生成脚本、本地 Emby 开发实例（Docker）
Scripts/          构建、打包、部署脚本
```

工程用 Xcode 16+ 的**同步文件夹**：往 `LumaPlayer/` 或 `LumaPlayerTests/` 下新增 `.swift`
会自动进编译，**不需要改 `project.pbxproj`**。

## 本地 Emby 开发实例

`Tools/emby-dev/` 提供一套 Docker 自建 Emby（固定 4.9.5.0），用于日常测试与手工验收 ——
这样就不必去碰别人的生产服务器。见该目录的 `README.md`。

## 说明

项目在开发过程中参考了 Emby 官方 OpenAPI 规格（`https://swagger.emby.media/openapi.json`，
Server API 4.1.1.0）与 Emby Web 自身的请求行为，所有接口结论都经过实测核对。

测试 fixture 全部为合成数据，不含任何真实服务器地址、用户名或 token。

## 许可证

[MIT](LICENSE)
