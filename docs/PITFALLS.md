# 踩坑记录

> 真实撞过的坑。每条只写「现象 → 原因 → 现在的做法」。带 `Qnn` 的是已结案问题,代码注释按编号引用;
> 未结案的在 `KNOWN_ISSUES.md`。

## 1. 构建、签名与工程

**ad-hoc 签名下凭据不进钥匙串。** ad-hoc 的 DR 只能是 cdhash,每次构建都变,钥匙串每次都当新程序弹窗;
给 ad-hoc 加显式 DR **也没用**(实测仍只认 cdhash)。所以 token / DeviceId / 密码存沙盒容器里的凭据文件
(`CredentialFileStore`)。

**别删钥匙串里 `com.local.LumaPlayer` / `deviceId` 那条旧条目,也别重置损坏的凭据文件。**
凭据文件丢了靠它重新导入同一个 DeviceId;生成新的会让 Emby 后台多一台重复设备。

**`ENABLE_HARDENED_RUNTIME` 保持 `NO`。** 生效时 `MPVPlayer()` 会让进程约 5 秒后无声死掉(Q18)。ad-hoc 下它本来不生效;
换回证书签名时会真正生效。⛔ 别因为「模板默认 YES」改回去。

**换回证书签名时:Team ID 是证书 subject 的 OU,不是 CN 括号里那串。** 填错报 `No certificate for team ... found`。

**entitlements 条数:文件里 3 条,Release 4 条,Debug 6 条**(Xcode 注入 `get-task-allow` 与两条 `temporary-exception.*`)。

**沙盒加载签名不同的 libmpv 需要 `disable-library-validation`(Q1)。**

**`project.pbxproj` 手写、同步文件夹(`objectVersion = 77`)。** 新增 `.swift` 自动进编译;`Info.plist` / `.entitlements`
靠 `membershipExceptions` 排除。scheme 里**不要留空的 `<TestPlans></TestPlans>`**,否则 `xcodebuild test` 退出码 66。

**新克隆必须先跑 `Scripts/build-libmpv.sh`。** App 链的是仓库内自编 libmpv(`Vendor/mpv/prefix/`,被 gitignore),
module map 与 `OTHER_LDFLAGS` 都指向那里。`brew upgrade` 换了 ffmpeg / libplacebo 大版本后,Debug 运行与测试会在加载期失败,
重跑脚本即可。mpv 源码改动只能写成 `Vendor/mpv/patches/*.patch`(脚本 `reset --hard` 后按序 `git apply`)。

**打包脚本只对 Release 产物跑,且只作用于拷出来的 App。** Debug 产物是桩 + `LumaPlayer.debug.dylib`,
从桩遍历 `otool -L` 会漏依赖;打包时要删指向 Homebrew 的 `LC_RPATH`。

**打包脚本必须用物理路径解析仓库根,否则静默收不到依赖。** 现象:`deploy-to-applications.sh` 走到「改写加载路径…」
后报 3 条 `otool-classic: can't open file: .../Contents/Frameworks/*.dylib`,然后无声退出。
原因:编译时写进二进制的 libmpv 路径是**物理**路径(编译器的 SRCROOT),而 `Scripts/*.sh` 里
`cd "$(dirname "$0")/.." && pwd` 拿到的是**逻辑**路径 —— 从软链或大小写不同的路径(如 `~/projects/LumaPlayer`)
调用脚本时两者对不上,`bundle-libmpv.sh` 的 `bundled_deps` 一条都匹配不到,`Frameworks/` 空着,
后面的 `"${FW}"/*.dylib` 就当成字面量传给了 `otool`。做法:4 个脚本统一用
`REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"`(`build-libmpv.sh` 也改,meson 的 prefix 会进 install name);
`bash` 内建 `pwd -P` **不够**——它只解软链,不改大小写。`bundle-libmpv.sh` 现在若一条依赖都没匹配到会直接报错并打印主程序的实际引用。

**只支持 macOS 27。** Homebrew 的依赖按 27.0 编译,Deployment Target 低于 27 会得到链接器 warning 且产物也只能在 27 上跑(Q3、Q26)。
⛔ 别把「支持 macOS 26」写回任何地方。

**`swift-plugin-server produced malformed response`,`@Observable` / `@State` 宏全线报错** —— 不是代码问题,是宏服务。
常见诱因:命令行沙箱拦了 `~/.swiftpm/security`(stderr 只有 `sandbox ... file-delete`)。处理:**前台**申请无沙箱执行
(后台任务里解除沙箱不生效;`-skipMacroValidation`、改 `HOME` 都无效)→ `pkill -f swift-plugin-server` → 清 DerivedData。

## 2. 播放内核(libmpv)

**头文件是 `<mpv/...>`,不是 `<libmpv/...>`。** opengl-cb 自 0.33 已失效,`--wid` 在 macOS 不稳定,网上旧教程别照抄。

**每次 draw 都 `update()` + 无条件 `render()`。** 非 ADVANCED_CONTROL 下 `mpv_render_context_update()` 的 flags 从不置位,
拿它 gate `render()` 会死锁(显示时钟不推进)。

**FBO 不能写死 0 —— 「有声音、黑屏」。** `CAOpenGLLayer` draw 时绑的是 layer 自己的 FBO(实测 1/7/8 不等),每帧
`glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING)` 传给 mpv。这个 bug 能骗过所有计数指标。mpv render 完会把绑定还原成 0,探针直接读会误判。

**画面偏移。** `MPVLayerView` 走 `makeBackingLayer`,渲染尺寸取 GL viewport,别让 `layout()` 把 layer 拽到父 layer 原点。

**认证头:`MPV_FORMAT_NODE` 数组,`mpv_initialize()` 之后、`loadfile` 之前设 `http-header-fields`。** 值里自带逗号。

**`track-list` 事件里的 `mpv_node` 归 mpv,⛔ 不得 `mpv_free_node_contents()`。** 会 talloc 断言(SIGABRT)。
必须同步解析完,节点只活到下一次 `mpv_wait_event()`。

**mpv 的轨道号不是 Emby 的 `MediaStream.Index`(Q21)。** `src-id` 从 1 起,直接上报整体偏一位;`ff-index` 碰巧一致但不保证。
规则在 `StreamIndexMapper`:同类型**内嵌**轨按出现顺序对应;转码流、外挂轨、条数对不上 → 整键不报。

**设了 `aid` / `sid` 要读回。** 设了不存在的轨会变 `no`。

**`slang` 挑不出「简体中文」,用户的 `mpv.conf` 也不会被读(`config=no`)。** 中文偏好由客户端判:`SubtitlePreference`
简体 → 繁体 → 只标了中文 → 判不出就不动。

**事件队列满了会静默丢事件。** 等帧 / 等结束的循环(测试、探针)要持续排空队列。

**事件线程的退出条件是独立的 `isStopping`,不是 `phase`。** 关窗时恰好来一个 END_FILE 会把 tearingDown 覆盖掉,
`shutdown()` 等满 5 秒 → UI 冻结。

**事件线程体不能强持有 self。** `Thread { [weak self] in self?.eventLoop() }` 会把 weak 提升为强引用一直持有;
每轮迭代取一次强引用、用完即弃。回归测试 `testPlayerDeallocatesWhenDroppedWithoutShutdown` 要先 sleep 0.2s。

**两把锁,锁序恒为 `renderMutex` → `mutex`。** 整帧 render 放进 `mutex` 会让主线程每次 pause/seek 都等一次 GPU 提交。

**播完不回到 `idle`(Q7)。** 一个 `MPVPlayer` 只播一个 URL,换台 = 销毁重建(复用会沿用上一轮的 `http-header-fields`,跨服务器串台);
EOF 只发 `endFile(.eof)` 事件。播完是事件不是状态,播完时 phase 可能停在 `.playing`,要看 `isEnded`。

**显示器休眠必须宿主自己持(Q34)。** `--stop-screensaver` 在 `vo=libmpv` 下不生效。`DisplaySleepAssertion` +
`PlayerViewModel.shouldPreventDisplaySleep`(playing、未暂停、未播完才持;`stop()` 无条件释放);
`isolated deinit` 兜底,但持有者有引用环时 deinit 不跑,别绕开 `stop()`。

**`time-pos` 通知只有 3.4–3.6 次/秒。** 要更细的进度做插值,别指望调高频率。

**杜比视界发紫发绿 = legacy `gpu` 渲染器不处理 DV 的 RPU。** 解:render context 传
`MPV_RENDER_PARAM_BACKEND = "gpu-next"`(来自未合并的 draft PR mpv-player/mpv#16818,所以要自编 libmpv)。

**create 成功 ≠ gpu-next 生效。** 传不认识的后端名 mpv 不报错、静默回退且 `rc=0`。回退逻辑只按 create 真失败设计,
⛔ 别声称能检测静默回退;要确证看日志 `Using gpu-next backend.` 或用真实 DV 片源看画面。

**⛔ 别在 `mpv_initialize()` 之前设 gpu-next 专属选项。** `MPVPlayer.init` 把任何 `mpv_set_option_string` 失败当致命,
legacy 后端不认识这些选项 → 连回退也崩。要加就 post-create 用 `mpv_set_property_string` 非致命设置。

**gpu-next 能耗爆表 = 硬解退成了 `videotoolbox-copy`(补丁 0003)。** PR 后端不注册 hwdec 设备。补丁注册 VT 设备 + IOSurface 映射;
① libplacebo 的 GL 后端采样不了 `GL_TEXTURE_RECTANGLE`,要先 `pl_tex_blit` 到 2D 纹理;② libplacebo 外调 GL 残留的错误码会被它下一次
`glGetError` 认领(看到 `pl_generate_blue_noise` 吃 CPU 就开 `libmpv_render=trace` 找第一条 GL 报错)。验收:统计「解码」是 `videotoolbox` 不是 `-copy`。

**draft PR 后端上下颠倒、闪烁(补丁 0001)。** `render()` 不读 `FLIP_Y`;参数零初始化 + 写死最近邻缩放。改用默认参数时⚠️ 同时
`frame_mixer = NULL`。翻转设目标**平面** `flipped`,⛔ 别翻 crop(OSD / 字幕不跟着翻)。

**换音频设备(连蓝牙耳机)崩溃 = `ao_coreaudio` 初始化失败时漏注销热插拔监听(补丁 0002)。** 病根在更早那次初始化失败
(设 `ChannelMap` 报 `-50`,当时以为只有 5.1 + 立体声设备,其实 macOS 27 上任何布局都失败,见下一条),之后任何设备变化
回调读野指针。复现不用真插拔:同进程建一个私有聚合设备即可。

**改倍速卡顿、越拖越卡 = 实际跑的是 `ao_avfoundation`(补丁 0004)。** macOS 27 上 `ao_coreaudio` 设 `ChannelMap` 必报 `-50`
(上游 #18384),mpv 静默回退 avfoundation;它往 `AVSampleBufferAudioRenderer` 预排约 2 秒已按旧倍速拉伸的音频,改 `speed`
后 mpv 按新倍速换算这段缓冲,音频时钟一下跳几秒(2×→1× 实测 `audio-pts` 0.1 秒内跳 3.6 秒),视频只能连续丢帧追。
render API 下 VO 也没有「睡到目标时刻」的余量,小步来回改同样每次丢帧。排查先看 `current-ao`;
⚠️ 拿 Homebrew mpv 对照时别加 `--ao=coreaudio`:强制后初始化失败就没声音,视频按系统时钟走,反而「看不出问题」。
Q43 结案(2026-10-13):离屏 harness 丢帧 16–89 → 0;倍速观感、声道、5.1 下混、蓝牙切换经人工确认。上游修好 #18384 后删补丁 0004。

**补丁 0004 只把 `ChannelMap` 失败降为告警还不够,必须丢掉那个 AudioUnit 重建。** 设映射被拒后的 unit `AudioOutputUnitStart`
返回成功,但渲染回调一次都不调 → 音频时钟不走,画面停在首帧、缓冲照涨、播放 / 暂停都没反应,`current-ao` 却显示 coreaudio。
最小复现:DefaultOutput unit 依次设 StreamFormat、CurrentDevice、ChannelMap(-50)、回调、Start,1 秒回调 0 次;跳过 ChannelMap 则约 94 次。
排查「首帧出来就不动」先看 `time-pos` 是否推进、`current-ao` 是谁。
⚠️ 上一条 Q43 的「丢帧 16–89 → 0」大概率是在这个卡死状态下测的(不播自然不丢帧),作废;重建 unit 后 `vo=null` 离屏实测
2×→1× 一次丢 4 帧,倍速观感需重新人工确认(2026-10-13)。

**`NSWindow.isReleasedWhenClosed` 默认 YES。** 手动建窗口交给 ARC 时置 `false`,否则 `close()` 过度释放。

**测试媒体要 faststart(`-movflags +faststart`)。** moov 在尾部 + 服务器不支持 Range 时流不可 seek,首帧永不就绪。

**mpv 的文件没加载好时,`seek` 命令一律返回 `-12`(`MPV_ERROR_COMMAND`)。** 返回值只说明「跑了但失败」,
分不出「还没加载好」和「流真不可 seek」。本机 C 探针直接调 `mpv_command` 实测(`Vendor/mpv/prefix` 的 libmpv 2.5.0):
没 loadfile → -12;`loadfile` 后未 `FILE_LOADED` → -12;**`FILE_LOADED` 那一刻起 → 0**;播完(`END_FILE` eof,
mpv 已卸载文件、而 phase 仍停在 `.playing`)→ 又回到 -12。
⚠️ `duration` 属性与 `FILE_LOADED` **同时**到达 —— 「时长已知」不能当「能 seek」用:百度源的总时长在会话准备阶段
就填上了(比加载文件早得多),那一段时间进度条是可拖的。
所以判据是**内核里有文件**(`FILE_LOADED` 后进入 `.playing`),不是时长;而拖动失败**绝不能再写进 `failure`**
—— 那是整页覆盖层、且不拆播放器,会直接压在正常播放的画面上(2026-10-14 修的「刚开播拖进度条弹『拖动失败』,
底下视频照常播」,判据见 `PlayerViewModel.isReadyToSeek` / `allowsSeeking`)。

**沙盒 App 收不到 `open --args`,直接 exec 会 SIGTRAP。** 外部驱动只能靠 URL scheme;开发期 spike 的 scheme 已删(留着等于任何网页都能让 App 播任意 URL)。

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

**DirectStream 403 来自跳转后的推流节点。** 部分服务器 `/videos/{id}/original.mkv` 回 301 跳到另一个 host 的推流节点,
地址自带签名(不需要 `api_key`),节点按 UA 白名单放行:带不带认证头都 403,在设置里填白名单播放器的 UA 后能播。
ffmpeg 自己跟随跳转,日志里只看得到最终的 403;`PlaybackFailureProbe` 遇 4xx/5xx 会记下跳转目标并对它各探一次。

**禁用账户登录返回 403 不是 401。** 客户端显示「没有访问权限」,与真实原因不符;本地实例可复现。

**迟到的旧 token 401 曾把刚存的新 token 删掉。** 现在只删那次请求用的 token。

**可续播由服务端判定**(`MinResumePct` / `MaxResumePct` / `MinResumeDurationSeconds` 默认 120 秒:更短的素材中途停只标已看、进度存 0)。客户端不复刻。

**本地实例的结论不能当真实服务器也成立。** 「继续观看」第一版就栽在这。

## 4. App 行为

**关窗后同一详情页再点播放从旧位置起播(Q22)。** 要等 Stopped 真正发完(`PlaybackProgressReporter.drain()`)再重读详情。

**编辑服务器地址后浏览仍用旧地址。** `AppContainer.connections` 缓存了持有档案副本的连接。凡是按 id 缓存了档案副本的对象,
改档案的每条路径都要让缓存失效;地址变了要重新探测,探测不通不保存。

**倍速:上报要带当前值、滑块要合并上报、新建播放器要设回去。** 改成连续滑块后一次拖动十几个请求 → `scheduleRateChangeReport()`
延后 0.5s 互相取消。转码 seek、下一集、重开都会新建播放器(默认 1×)→ `PlaybackSpeedStore`(键 = `PlaybackSpeedScope`),
在**起事件泵之前**设回去;⛔ 不落 UserDefaults。凡是从离散改连续的控件,回头看副作用是按次还是按值触发。

**「同一部剧沿用倍速」的键是来源无关的,百度那一路判错就会「点下一集被打回 1×」。** 键分两段(隔离 + 内容):
Emby 是「服务器 id + `SeriesId`」(电影退化成 Item Id);百度是「账号常量 + **剧目录**」
(`BaiduPanPath.seriesDirectory`,所以 `琅琊榜/第1季` → `第2季` 也跟得过去)。⚠️ 百度**不是剧集时要退化成 `fs_id`** ——
一律用目录会让同一个目录下的几部电影互相串台。判「是不是剧集」只能看 `episodeQueue`:它由浏览页装配后随请求带进来,
起播前就有值,⛔ 别去等列网盘。

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
(2026-10-15 起主窗口不再用系统工具栏与 `.searchable`,搜索框在浮动顶栏 `ChromeSearchField` 里;将来回到系统工具栏时这条仍然成立。)

**原生全屏下详情页那条工具栏背景去不掉(Q37)。** 全屏时系统把工具栏搬进独立的 `NSToolbarFullScreenWindow`,
`.toolbarBackgroundVisibility` / `.scrollEdgeEffect*` / `.windowToolbarFullScreenVisibility` 都不生效;
唯一生效的 `.toolbarVisibility(.hidden)` 会连按钮一起藏掉。⛔ 别再试这一类修饰符。
2026-10-15 的做法:主窗口整条藏掉系统工具栏(`.toolbar(.hidden, for: .windowToolbar)` + 窗口 `.hiddenTitleBar`),
返回 / 搜索 / 来源画成浮在内容上的玻璃按钮(`BrowseChromeBar.swift`),全屏下随指针自动隐藏。
全屏下那条栏是否真的消失:**未视觉验证**(见 KNOWN_ISSUES.md B 节)。

**共用工具栏的「刷新」靠各页 `.task(id:)` 吃 `refreshToken`(Q36)。** 详情页曾漏接,刷新成空操作。每个新页面都要确认。

**`.sheet(item:)` 的内容里 ⛔ 别用 `if let` 去取第二个 `@State`(第一次弹出的是空白面板)。** 百度「按 TMDB 命名重命名」曾这么写:一个状态装目录、
另一个装流程 ViewModel,sheet 内容里 `if let viewModel`。后果是**第一次右键弹出一个空白面板** ——
sheet 的内容闭包在状态提交落地之前就被求值,那次读到的还是上一次的值(nil),面板便建成了空的,而且不会再补内容。
第二次点之所以看着"恢复正常",只是因为上一轮写进去的 ViewModel 还在,**显示的是上一部剧的进度**。
做法:两样东西装进**同一个** `Identifiable` 载荷(`RenameRequest`)一起交给 `.sheet(item:)`,内容闭包只读它 ——
也仍然满足「⛔ ViewModel 不在内容闭包里新建」(闭包会重算,每重算一次丢一次进度)。
⚠️ 这种载荷的 `id` 要用 `UUID`,⛔ 别用目录的 `fs_id`:同一目录连着改两次时 id 相同,
`BaiduPanRenameSeriesView` 的 `@State didStart` 会被复用,第二次不会重新走 `start`,面板卡在上一轮结果上。

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
| Q43 | `S0` / `Season 0` / `第0季` 认季号 **0**(特别篇,`TMDB_API.md` §7);季文件夹分支**不套** `looksLikeEpisodeSequence` 闸门 —— 套了会把剧名认成季文件夹名 |
