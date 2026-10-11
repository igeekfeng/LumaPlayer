# 踩坑记录

> 真实撞过的坑。每条只写「现象 → 原因 → 现在的做法」。带 `Qnn` 的是已结案问题,代码注释按编号引用;
> 未结案的在 `KNOWN_ISSUES.md`。

## 1. 构建、签名与工程

**ad-hoc 签名下凭据不进钥匙串。** ad-hoc 的 DR 只能是 cdhash,每次构建都变,钥匙串每次都当新程序弹窗;
给 ad-hoc 加显式 DR **也没用**(实测仍只认 cdhash)。所以 token / DeviceId / 密码存沙盒容器里的凭据文件
(`CredentialFileStore`)。

**别删钥匙串里 `com.local.LumaPlayer` / `deviceId` 那条旧条目,也别重置损坏的凭据文件。**
凭据文件丢了靠它重新导入同一个 DeviceId;生成新的会让 Emby 后台多一台重复设备。

**`ENABLE_HARDENED_RUNTIME` 保持 `NO`。** 旧内核下生效时 `MPVPlayer()` 会让进程约 5 秒后无声死掉;Erika 下未验证。
ad-hoc 下它本来不生效,换回证书签名时才会真正生效。⛔ 别因为「模板默认 YES」改回去。

**换回证书签名时:Team ID 是证书 subject 的 OU,不是 CN 括号里那串。** 填错报 `No certificate for team ... found`。

**entitlements 条数:文件里 3 条,Release 4 条,Debug 6 条**(Xcode 注入 `get-task-allow` 与两条 `temporary-exception.*`)。

**`project.pbxproj` 手写、同步文件夹(`objectVersion = 77`)。** 新增 `.swift` 自动进编译;`Info.plist` / `.entitlements`
靠 `membershipExceptions` 排除。scheme 里**不要留空的 `<TestPlans></TestPlans>`**,否则 `xcodebuild test` 退出码 66。

**Erika 走 SwiftPM,解析要联网。** `Package.resolved` 入库锁 revision;首次 / 换机 `xcodebuild -resolvePackageDependencies`
会去 GitHub 拉 xcframework.zip。测试 target 不链接 Erika。

**只支持 macOS 27。** ⛔ 别把「支持 macOS 26」写回任何地方;要放宽先核对 Erika 产物的最低系统要求。

**`swift-plugin-server produced malformed response`,`@Observable` / `@State` 宏全线报错** —— 不是代码问题,是宏服务。
常见诱因:命令行沙箱拦了 `~/.swiftpm/security`(stderr 只有 `sandbox ... file-delete`)。处理:**前台**申请无沙箱执行
(后台任务里解除沙箱不生效;`-skipMacroValidation`、改 `HOME` 都无效)→ `pkill -f swift-plugin-server` → 清 DerivedData。

## 2. 播放内核

> libmpv 时代的坑(渲染循环、FBO、`mpv_node`、事件线程、gpu-next 补丁…)随换内核作废,留在 `main` 分支的 `docs/PITFALLS.md` 里。

### 与内核无关、仍然成立的

**内核的轨道号不是 Emby 的 `MediaStream.Index`(Q21)。** 旧内核 `src-id` 从 1 起,直接上报整体偏一位。
规则在 `StreamIndexMapper`:同类型**内嵌**轨按出现顺序对应;转码流、外挂轨、条数对不上 → 整键不报。

**设了选中轨要读回。** 以 `trackSelection()` 为准,不能假设设置即生效。

**内核挑不出「简体中文」。** 中文偏好由客户端判:`SubtitlePreference` 简体 → 繁体 → 只标了中文 → 判不出就不动。

**播完不回到 `idle`(Q7)。** 一个引擎只播一个 URL,换台 = 新建(复用会沿用上一轮的请求头,跨服务器串台)。
播完是事件不是状态,播完时 phase 可能停在 `.playing`,要看 `isEnded`。

**显示器休眠必须宿主自己持(Q34)。** `DisplaySleepAssertion` + `PlayerViewModel.shouldPreventDisplaySleep`
(playing、未暂停、未播完才持;`stop()` 无条件释放);`isolated deinit` 兜底,但持有者有引用环时 deinit 不跑,别绕开 `stop()`。

**`NSWindow.isReleasedWhenClosed` 默认 YES。** 手动建窗口交给 ARC 时置 `false`,否则 `close()` 过度释放。

**测试媒体要 faststart(`-movflags +faststart`)。** moov 在尾部 + 服务器不支持 Range 时流不可 seek,首帧永不就绪。

**沙盒 App 收不到 `open --args`,直接 exec 会 SIGTRAP。** 外部驱动只能靠 URL scheme;开发期 spike 的 scheme 已删(留着等于任何网页都能让 App 播任意 URL)。

### Erika

**没有 EOF 事件,必须推断(`EofDetector`)。** 位置到过末尾 + 收到 `stopped` / `closed` + 不是本地主动停 → `.eof`。
本地停之前必须 `markLocalStop()`,否则关窗会被当成播完。

**音量 / 倍速没有读回,只能乐观更新;静音 = 向引擎写音量 0。** ⛔ 别写「从内核读回音量 / 倍速」。

**倍速在新建引擎后回到 1×。** 转码 seek、下一集、重开都会新建引擎,要在起事件泵之前把 `PlaybackSpeedStore` 里的值设回去(第 4 节)。

**HTTP 预读默认只有 2 MiB,播放基本无缓冲。** 换内核时以为 Erika 不暴露缓存调参而一直传 0;其实 `open` 有
`httpReadAheadBytes` / `httpBackBufferBytes`,现为 128 / 64 MiB(`ERIKA_INTEGRATION.md` §6.1)。

**统计字段是近似,给不了就不显示。** 「丢帧」是背压丢帧,「显存」是渲染器跟踪的;⛔ 不填「未知 / 0」占位。

**`@unchecked Sendable` 的例外已取消。** 旧内核 `Core/MPV/` 曾是唯一例外目录;`ErikaPlayer` 是 `@MainActor`,全项目自检应无输出。

## 3. Emby 接口

**没有 Direct Play。** `EnableDirectPlay` 固定 false;HTTP 拉原文件叫 Direct Stream。

**`URLComponents(string: "https://")` 的 host 是 `""` 不是 nil。** `guard let host` 放过它,要同时判 `!host.isEmpty`。

**`/Items/Latest` 返回裸数组(Q23)。** 当初按类推解码,首页「最近添加」整段失败;手写 fixture 也按包裹对象写的,所以单测没抓到。

**「继续观看」两台服务器结论相反。** 4.9.5.0 上 `/Items/Resume` 不带参数恒 0 条;4.7.11.0 上 `/Items?Filters=IsResumable`
不带 `ParentId` 返回媒体库条目。定案照抄 Emby Web:`/Users/{uid}/Items/Resume?Recursive=true&MediaTypes=Video`。
⛔ 剧集页定位别换成 `Resume?ParentId=...`,它会把进度为 0 的集也返回。

**「继续观看」里电影没封面(Q35)。** 电影常常只有 `ImageTags["Primary"]`;有的服务器把 Primary 的 tag 回填进
`BackdropImageTags` 但 Backdrop 实际 404。`EmbyItem.coverImage` + `coverImageFallback` 两级交给 `PosterImage`。

**`/Shows/NextUp` 路径里没有 `{Id}`(Q25)。** 剧集页定位 = NextUp → 可续播 → 第一集。

**首页「下一集」在用户服务器上 400 `SeriesId is required`(Q31)。** 后来所有服务器上这一行都「加载一下就消失」,已去掉;
剧集页带 `SeriesId` 的 NextUp 不受影响。

**禁用账户登录返回 403 不是 401。** 客户端显示「没有访问权限」,与真实原因不符;本地实例可复现。

**迟到的旧 token 401 曾把刚存的新 token 删掉。** 现在只删那次请求用的 token。

**可续播由服务端判定**(`MinResumePct` / `MaxResumePct` / `MinResumeDurationSeconds` 默认 120 秒:更短的素材中途停只标已看、进度存 0)。客户端不复刻。

**本地实例的结论不能当真实服务器也成立。** 「继续观看」第一版就栽在这。

## 4. App 行为

**关窗后同一详情页再点播放从旧位置起播(Q22)。** 要等 Stopped 真正发完(`PlaybackProgressReporter.drain()`)再重读详情。

**编辑服务器地址后浏览仍用旧地址。** `AppContainer.connections` 缓存了持有档案副本的连接。凡是按 id 缓存了档案副本的对象,
改档案的每条路径都要让缓存失效;地址变了要重新探测,探测不通不保存。

**倍速:上报要带当前值、滑块要合并上报、新建播放器要设回去。** 改成连续滑块后一次拖动十几个请求 → `scheduleRateChangeReport()`
延后 0.5s 互相取消。转码 seek、下一集、重开都会新建播放器(默认 1×)→ `PlaybackSpeedStore`(键 = 服务器 + `SeriesId`,电影退化成 Item Id),
在**起事件泵之前**设回去;⛔ 不落 UserDefaults。凡是从离散改连续的控件,回头看副作用是按次还是按值触发。

**播放有剧照的分集时崩溃。** `MPMediaItemArtwork` 的 `requestHandler` 写在 `@MainActor` 类型里继承了主线程隔离,
MediaPlayer 在别的队列调它 → `EXC_BREAKPOINT`。交给系统框架在任意队列回调的闭包,在 `nonisolated static` 方法里创建。

**全屏无效(Q19)。** `Window` 场景的 `collectionBehavior` 是 `.fullScreenAuxiliary`;`WindowBox` 每次切换前设为 `.fullScreenPrimary`。

**缓存:登录验证必须绕过缓存**(否则失效 token 假装登录成功);写操作作废整台缓存时,之前发出的读请求回来仍会写旧数据 →
per-server epoch;Progress 每 10 秒一次,不能触发失效。图片内存缓存用 LRU,别超限全清(会让另一台服务器的海报陪葬)。

**单元测试跑在宿主 App 进程里,共享沙盒容器。** 诊断日志要挡测试进程,否则一次全量测试冲掉真实排障记录。

**控制栏自动隐藏是两条规则:「静止 2 秒」和「指针移出窗口 0.3 秒」。** 只做了移出那条,播放中移动鼠标后就再也不收。
引用外部规范时先判断「A 这么做、B 那样做」是并列还是互斥。

**`Task.cancel()` 拦不住已经过了 `sleep` 的任务。** 转码 seek 合并任务关窗后照样起流 → `restartEpoch` 代次门。
延时任务的取消要同时给一道代次门。另:`isRestarting = true` 要写在 `stop()` 之后。

**工具栏搜索框挂在 `NavigationStack` 外面就不出现(macOS 27)。** 挂到栈根和每个 `navigationDestination` 页上。改导航容器后逐项核对工具栏。

**原生全屏下详情页那条工具栏背景去不掉(Q37,定案保持现状)。** 全屏时系统把工具栏搬进独立的 `NSToolbarFullScreenWindow`,
`.toolbarBackgroundVisibility` / `.scrollEdgeEffect*` / `.windowToolbarFullScreenVisibility` 都不生效;
唯一生效的 `.toolbarVisibility(.hidden)` 会连按钮一起藏掉。⛔ 别再试这一类修饰符。

**共用工具栏的「刷新」靠各页 `.task(id:)` 吃 `refreshToken`(Q36)。** 详情页曾漏接,刷新成空操作。每个新页面都要确认。

## 5. 工具与环境

**沙盒 App 写不了 `~/Library/Logs`。** 诊断日志在容器里(路径见 `CLAUDE.md`);系统日志
`/usr/bin/log show --last 10m --predicate 'subsystem == "com.local.LumaPlayer"' --info`(zsh 里裸 `log` 是内建命令)。

**本机 `grep` 可能是 rg 的别名。** 用 `/usr/bin/grep`。BSD `grep -E` 不支持 lookahead,所以脱敏检查是两段 grep。

**Docker Desktop for macOS 不支持 `network_mode: host`**,CLI 常不在 PATH。本地实例的其他坑见 `Tools/emby-dev/README.md`。

**读异步落盘的日志要轮询等标志行出现,不要固定 sleep。**

## 附:其余已结案编号

| 编号 | 一句话 |
|---|---|
| Q4 | 图标由 `Tools/app-icon/render-icon.swift` 绘制,改脚本重跑,不手改 PNG |
| Q5 / Q8 | 真实服务器都不是自己的 →「禁用转码的服务器」构造不了,用本地实例与 mock |
| Q9 | `SecretRedactor` 脱敏 `api_key=`、`X-Emby-Token`、整行 `Authorization`、JSON 里的 `Pw` / `Password` |
| Q10 | 登录体 `{"Username", "Pw"}` 与 `/System/Info/Public` 免认证已在 4.7.11.0 实测;不做小写 `pw` 重试 |
