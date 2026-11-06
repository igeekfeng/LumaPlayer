# CLAUDE.md

LumaPlayer 是自用的 macOS 原生 Emby 播放器,SwiftUI + **libmpv**(自编,带 gpu-next 后端),**仅 macOS 27** + Apple Silicon。

## 注释
精简 —— 历史看 git;删掉的东西直接删,不留墓碑;不复述代码。

`Qnn` / `M2` / `M4` 是问题编号,未结案在 `KNOWN_ISSUES.md`,已结案在 `PITFALLS.md`。
提交信息 / PR 描述里引用上游 issue / PR 不写 owner/repo#N 或完整 GitHub 链接,写成 mpv PR 16818 这类不被识别的形式。

## 硬规则

- **不用 `@unchecked Sendable` / `nonisolated(unsafe)` / `@preconcurrency` / 降回 Swift 5 消除并发报错**。
   唯一例外是 `Core/MPV/` 下包裹 C 指针的类型,须注释论证线程安全(见「并发分层」)。
- **不静默吞错、不用假数据占位**。⛔ 空数组 / 假数据 / `try?` 让上层「看起来能跑」;做不了的分支明确抛错并登记
   `KNOWN_ISSUES.md`。缺省值只在 UI 层决定,不进模型层。
- **改动收敛在任务范围内**。顺手发现的问题记进 `KNOWN_ISSUES.md` 或单独提。

## 常用命令

```bash
# 新克隆先还原 libmpv(产物在 Vendor/mpv/prefix/,被 gitignore;零额外工具,不需要 brew)
./Scripts/build-libmpv.sh
# 构建(必须零编译器 warning)
xcodebuild -scheme LumaPlayer -destination 'platform=macOS,arch=arm64' build
# 全部测试 / 单个测试类
xcodebuild -scheme LumaPlayer -destination 'platform=macOS,arch=arm64' test
xcodebuild -scheme LumaPlayer -destination 'platform=macOS,arch=arm64' -only-testing:LumaPlayerTests/SmokeTests test
```

判定看**退出码**。`appintentsmetadataprocessor: ... no AppIntents.framework dependency found` 是信息性输出;
数真 warning 用 `grep -cE '\.swift.*warning:'`。遇到 `swift-plugin-server produced malformed response` 先看 `PITFALLS.md` 第 1 节。

- 安装到本机:`./Scripts/deploy-to-applications.sh`(Release 构建 → 打包 libmpv → 拷到 `/Applications` → 校验签名 → 启动;
  `--no-build` 只拷,`--no-open` 不启动)。打 DMG:`./Scripts/make-dmg.sh`(`build/LumaPlayer-{版本}-{构建号}.dmg`)。
  两者都调 `Scripts/bundle-libmpv.sh` 把 libmpv 及依赖打进 `Frameworks/`。ad-hoc 签名、未公证,只在自己的 Mac 上用。
- 图标源是 `Tools/app-icon/render-icon.swift`,生成 Icon Composer 文档 `LumaPlayer/Resources/AppIcon.icon`(SVG 图层 + `icon.json`,
  玻璃与深色 / 着色外观由系统渲染);改脚本后重跑,不手改 `.icon` 里的文件。
- 诊断日志(只记失败请求,已脱敏):`~/Library/Containers/com.local.LumaPlayer/Data/Library/Logs/LumaPlayer/network.log`。
  凭据文件(含 token,⛔ 不要整段贴出):同容器下 `Library/Application Support/LumaPlayer/credentials.json`。

### 提交前自检(仓库根执行)

```bash
# (1) 密钥泄漏,应无输出
grep -rEio '(accesstoken|api_key|x-emby-token)"?[[:space:]]*[:=][[:space:]]*"[^"]*"' \
  LumaPlayerTests/Fixtures/ 2>/dev/null | grep -v 'FAKE_'
# (2a) 全项目禁止,应无输出
grep -rn 'nonisolated(unsafe)\|@preconcurrency' LumaPlayer/
# (2b) 只允许出现在 Core/MPV/,应无输出
grep -rn '@unchecked Sendable' LumaPlayer/ | grep -v 'LumaPlayer/Core/MPV/'
# (3) 强解包 / 强制转换(人工复核)
grep -rnE '(as!|try!|[A-Za-z0-9_)\]]![^=])|[A-Za-z0-9_)\]]!$' LumaPlayer/Models/
# (4) 散落的 ticks 字面量,应只在 TickConverter.swift
grep -rnE '10{7}|10_000_000|1[eE]-?7|0\.0000001' LumaPlayer/ | grep -v 'TickConverter.swift'
# (5) 隐私:真实域名、个人信息、本机路径、疑似密钥
./Scripts/check-privacy.sh
```

(1)(2a)(2b) 有输出必须修;(5) 的命中逐条确认是不是真实服务器 / 个人信息。(3)(4) 有误报也有漏报。

### 产物检查

```bash
APP_PATH="$(xcodebuild -scheme LumaPlayer -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')"
lipo -archs "$APP_PATH/Contents/MacOS/LumaPlayer"        # 期望 arm64
codesign -d --entitlements - "$APP_PATH"                  # Release / Debug 均 6 项(5 条 + get-task-allow)
codesign -d -r- "$APP_PATH"                               # ad-hoc:DR 是 cdhash,属预期
```

## 工程的非常规点

**`LumaPlayer.xcodeproj` 手写入库,用 Xcode 16+ 同步文件夹**(`objectVersion = 77`)。往 `LumaPlayer/` / `LumaPlayerTests/`
下新增 `.swift` 自动进编译,不改 `project.pbxproj`。`Info.plist` 与 `.entitlements` 在 `Resources/` 下但用
`membershipExceptions` 排除在 target 成员外,新增非编译资源时注意。scheme 里**不要留空的 `<TestPlans></TestPlans>`**(退出码 66)。

**ad-hoc 签名,凭据不进钥匙串。** `CODE_SIGN_IDENTITY = "-"`、`CODE_SIGN_STYLE = Manual`、`DEVELOPMENT_TEAM = ""`、
`ENABLE_HARDENED_RUNTIME = NO`。

- ad-hoc 的 DR 是每次构建都变的 cdhash,钥匙串 ACL 认它 → ⛔ 新代码不往钥匙串存东西(加显式 DR 也没用,已实测)。
- ⛔ 换回证书签名时不要打开 hardened runtime:`MPVPlayer()` 会让进程约 5 秒后无声死掉(Q18)。
- entitlements 5 条:`app-sandbox`、`network.client`(没有它所有请求静默失败)、`cs.disable-library-validation`(加载自编 libmpv,Q1)、
  `files.user-selected.read-only` + `files.bookmarks.app-scope`(打开本地字幕;本地文件夹来源的只读安全作用域书签,见 `LocalFolderAccess`)。
- Info.plist 的 ATS 只开 `NSAllowsLocalNetworking`(公网仍强制 HTTPS),⛔ 不要 `NSAllowsArbitraryLoads`。

## 架构主线

### 播放只有两条路径,由服务端决定

```
POST /Items/{Id}/PlaybackInfo(EnableDirectPlay 固定 false)
        ↓
PlaybackDecisionEngine  ← 纯函数,无网络 / IO / 时间依赖,靠 fixture 测
        ↓
DirectStream(DirectStreamUrl / static=true) 或 Transcode(TranscodingUrl)
        ↓
PlayerViewModel → PlaybackSessionCoordinator → MPVPlayer → libmpv
```

- 没有 Direct Play(那是客户端直读文件系统)。`PlaybackPlan` 只有 `.directStream` / `.transcode`,⛔ 不加 `direct` / `directPlay`。
- 两条都不满足时**抛错**,不自己拼猜的 URL(`API_CONTRACT.md` 4.4)。
- **Seek 不同**:DirectStream 交给内核;Transcode 必须停流 + `StartTimeTicks` 重新起流。
- 时长与章节取 `MediaSource` 上的,不是外层 Item 的。
- 一个 `MPVPlayer` 只播一个 URL,换台 = 新建;播完是事件不是状态。
- 播放器是单实例独立窗口(`Window` 场景),不依赖导航页面;关窗触发最终上报。

### 每台服务器完全隔离

- 每台一个 `ServerConnection` / `EmbyAPIClient`,**token 不共享**;删服务器时删它的 token、密码与缓存。
- token 存凭据文件(`CredentialFileStore`,0600、不进备份),按 `ServerProfile.id` 区分。**密码默认不存**,仅勾了「记住密码」才存,
  用于 401 / 缺 token 时静默重登一次(`API_CONTRACT.md` 2.5)。
- `DeviceId` 全 App 唯一,删服务器时**不删**。⛔ 凭据文件损坏时不要重置;⛔ 不要删钥匙串里 `com.local.LumaPlayer` / `deviceId` 旧条目。
- 播放上报经 actor 串行化并带 generation,切媒体 / 切服务器时 +1、丢弃旧结果。
- 接口响应缓存 key 含 serverID、不含 host;写操作、开始 / 停止播放、登录登出时整台作废。

### 认证头(写错这里是最高频的失败原因)

```
Authorization: Emby UserId="{uid}", Client="LumaPlayer", Device="{host}", DeviceId="{uuid}", Version="{ver}"
X-Emby-Token: {accessToken}
```

- token 走**独立的 `X-Emby-Token` 头**;⛔ 不用 `X-Emby-Authorization: MediaBrowser ...`(Jellyfin 风格)。
- 未登录时**省略整段 `UserId="..."`**。`Device` 含非 ASCII 回退为 `Mac`。
- 图片同样带完整认证头 → **禁止裸用 `AsyncImage`**,统一走 `PosterImage`。
- 传给 mpv 的头用 `MPV_FORMAT_NODE` 数组(值自带逗号,`MPV_INTEGRATION.md` §5)。

### 并发分层

| 层 | 隔离 |
|---|---|
| `Models/` DTO | `struct` + `Sendable`;需要引用类型时 `final class` + 全 `let` |
| `Core/Network/` `EmbyAPIClient`、`Core/Servers/` `ServerRegistry` / `ServerConnection`、`Core/Security/`、`PlaybackProgressReporter`、`Core/Cache/`、`Core/Subtitles/` `SubtitleFileStore` | `actor` |
| `PosterImageStore`(缓存 `NSImage`) | `@MainActor` |
| `PlaybackDecisionEngine` | 纯函数 |
| `Features/` ViewModel | `@MainActor` + `@Observable` |
| `Core/MPV/` | 唯一允许 `@unchecked Sendable` 的目录(C 指针),锁序 `renderMutex` → `mutex` |

- ⛔ 不给所有类型撒 `@MainActor`。
- 遇到 `call to actor-isolated instance method ... in a synchronous actor-isolated context`:让方法 `async`,不是加逃逸标注。
- ⛔ View 不拼端点、不读 token;ViewModel 不构造 URL,一律经 `ServerConnection`。

### 安全与隐私

- 不在 `UserDefaults`、日志、诊断文件里存 token / 密码;日志与错误消息经 `SecretRedactor`(脱敏 `api_key`、token、`Authorization`、`Pw`)。
- 错误消息可含 host 与状态码,⛔ 不含完整带认证参数的 URL。
- 默认 HTTPS;局域网 http 回退的服务器在 UI 标「未加密连接」;⛔ 不实现「接受任意证书」。
