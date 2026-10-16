# CLAUDE.md

LumaPlayer 是自用的 macOS 原生 Emby 播放器,SwiftUI + **libmpv**(自编,带 gpu-next 后端),**仅 macOS 27** + Apple Silicon。
处于**维护迭代**:修 bug、按需加功能、跟进服务器差异。

## 文档

| 文件 | 内容 |
|---|---|
| `docs/API_CONTRACT.md` | Emby 接口唯一事实来源:端点、参数、字段、认证、错误映射、fixture 规范 |
| `docs/MPV_INTEGRATION.md` | libmpv 对接:构建、选项、事件、线程、轨道、字幕、生命周期 |
| `docs/PITFALLS.md` | 踩坑记录。改签名 / 构建 / 播放内核 / 接口代码前先扫一眼 |
| `docs/KNOWN_ISSUES.md` | 未决问题、待真实服务器核实项、待人工确认项 |

其余知识写在代码的文档注释里:设计 token 与 UI 硬约束在 `Components/DesignTokens.swift`,快捷键在
`Features/Player/PlayerCommands.swift`,缓存策略在 `Core/Cache/EmbyResponseCache.swift`,凭据存储在
`Core/Security/CredentialFileStore.swift`。**改了行为就同步改那里的注释**,不要另开文档。

引用约定:「API_CONTRACT.md 4.4」「MPV_INTEGRATION.md §8」是**章节编号**,编号稳定,改文档时不要重排;
`Qnn` / `M2` / `M4` 是问题编号,未结案在 `KNOWN_ISSUES.md`,已结案在 `PITFALLS.md`。

## 硬规则

1. **禁止发明 Emby 接口**。只用 `API_CONTRACT.md` 里标 ✅ / 🔶 的端点、参数、字段名。没有的先按其 0.2 核实
   (最可靠是看 Emby Web 自己怎么发请求),核实了回填文档再写代码;核实不了登记 `KNOWN_ISSUES.md`,别猜。
2. **禁止谎报验证状态**。判据是「这条命令我跑过并看到成功输出了吗」。本机**有** Xcode,build/test 结论必须真跑;
   **没有**真实 Emby 服务器,接口行为类结论如实标「未在真实服务器验证」;本地实例(4.9.5.0)的结论不能写成真实服务器也成立。
   本机**有**屏幕录制权限(`screencapture -x`),UI 外观结论要么亲眼看过截图,要么标「未视觉验证」;**没有**辅助功能权限,
   要交互才出现的画面(菜单、hover、手势)只能请人操作。截图只放 scratchpad、看完即删,⛔ 不进仓库。
3. **禁止用 `@unchecked Sendable` / `nonisolated(unsafe)` / `@preconcurrency` / 降回 Swift 5 来消除并发报错**。
   唯一例外是 `Core/MPV/` 下包裹 C 指针的类型,且必须注释论证线程安全。分层见下文「并发分层」。
4. **不静默吞错,不用假数据占位**。⛔ 不用空数组 / 假数据 / `try?` 让上层「看起来能跑」;做不了的分支明确抛错并登记
   `KNOWN_ISSUES.md`。缺省值只在 UI 层决定怎么展示,不写进模型层。
5. **改动收敛在任务范围内**。顺手发现的问题记进 `KNOWN_ISSUES.md` 或单独提。

## 真实服务器使用纪律(硬约束)

Emby 服务器**都不是自己的**,滥用会被封禁。手工验证一律**只读、低频率、单次请求**。

- ⛔ 压测、并发打同一台、循环刷列表;
- ⛔ 写操作(标记已看、删除、收藏、移出继续观看、改服务端设置)—— App 里这些按钮只在本地开发实例上点;
- ⛔ 故意构造异常请求(超大 `Limit`、畸形 `SearchTerm`);⛔ 去别人后台删设备制造 401;
- ⛔ 真实 host、服务器 Id、token 进仓库 —— fixture 与贴出的日志按 `API_CONTRACT.md` 9.3 脱敏,提交前跑自检。

异常分支用 `MockEmbyURLProtocol` 覆盖;要行为可控的真实 Emby 用本地实例 `Tools/emby-dev/`(Docker,4.9.5.0,见其 README)。

## 常用命令

```bash
# 新克隆先编 libmpv(产物在 Vendor/mpv/prefix/,被 gitignore;需 brew install meson ninja pkgconf)
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
- 图标源是 `Tools/app-icon/render-icon.swift`,改脚本后重跑,不手改 PNG。
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

(1)(2a)(2b) 有输出必须修;(5) 的命中逐条确认是不是真实服务器 / 个人信息。(3)(4) 有误报也有漏报,⛔ 不能因为无输出就声称「已确认无强解包」,只能写「(3)(4) 无输出」。

### 产物检查

```bash
APP_PATH="$(xcodebuild -scheme LumaPlayer -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')"
lipo -archs "$APP_PATH/Contents/MacOS/LumaPlayer"        # 期望 arm64
codesign -d --entitlements - "$APP_PATH"                  # Release 4 项 / Debug 6 项
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
- entitlements 3 条:`app-sandbox`、`network.client`(没有它所有请求静默失败)、`cs.disable-library-validation`(加载自编 libmpv,Q1)。
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
| `Core/Network/` `EmbyAPIClient`、`Core/Servers/` `ServerRegistry` / `ServerConnection`、`Core/Security/`、`PlaybackProgressReporter`、`Core/Cache/` | `actor` |
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
