# 踩坑记录

> 真实撞过的坑。每条只写「现象 → 原因 → 做法」。带 `Qnn` 的是已结案问题,代码注释按编号引用;
> 未结案的在 `KNOWN_ISSUES.md`。

## 1. 构建、签名与工程

**ad-hoc 签名下凭据不进钥匙串。** ad-hoc 的 DR 只能是 cdhash,每次构建都变,钥匙串每次都当新程序弹窗;
加显式 DR 也没用。所以 token / DeviceId / 密码存沙盒容器里的凭据文件(`CredentialFileStore`)。

**别删钥匙串里 `com.local.LumaPlayer` / `deviceId` 那条旧条目,也别重置损坏的凭据文件。**
凭据文件丢了靠它重新导入同一个 DeviceId;生成新的会让 Emby 后台多一台重复设备。

**`ENABLE_HARDENED_RUNTIME` 保持 `NO`。** 生效时 `MPVPlayer()` 会让进程约 5 秒后无声死掉(Q18)。ad-hoc 下它本来不生效,
换回证书签名时才会真正生效。

**换回证书签名时:Team ID 是证书 subject 的 OU,不是 CN 括号里那串。** 填错报 `No certificate for team ... found`。

**entitlements 条数:文件里 5 条,Release / Debug 均 6 条**(Xcode 注入 `get-task-allow`)。

**沙盒加载签名不同的 libmpv 需要 `disable-library-validation`(Q1)。**

**scheme 里不要留空的 `<TestPlans></TestPlans>`**,否则 `xcodebuild test` 退出码 66。

**新克隆必须先跑 `Scripts/build-libmpv.sh`。** module map 与 `OTHER_LDFLAGS` 都指向 `Vendor/mpv/prefix/`。
`brew upgrade` 换了 ffmpeg / libplacebo 大版本后 Debug 运行与测试会在加载期失败,重跑脚本即可。
mpv 源码改动只能写成 `Vendor/mpv/patches/*.patch`(脚本 `reset --hard` 后按序 `git apply`)。

**打包脚本只对 Release 产物跑,且只作用于拷出来的 App。** Debug 产物是桩 + `LumaPlayer.debug.dylib`,
从桩遍历 `otool -L` 会漏依赖;打包时要删指向 Homebrew 的 `LC_RPATH`。

**脚本必须用物理路径解析仓库根。** 二进制里的 libmpv 路径是编译器的物理路径;从软链或大小写不同的路径调用时,
`pwd` 拿到的逻辑路径对不上,`bundle-libmpv.sh` 一条依赖都匹配不到、`Frameworks/` 空着。
做法:`REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"`(`pwd -P` 不改大小写,不够)。

**只支持 macOS 27。** Homebrew 的依赖按 27.0 编译,Deployment Target 低于 27 会有链接器 warning 且产物也只能在 27 上跑(Q3、Q26)。

**`swift-plugin-server produced malformed response`,`@Observable` / `@State` 宏全线报错** —— 不是代码问题,是宏服务。
常见诱因:命令行沙箱拦了 `~/.swiftpm/security`(stderr 只有 `sandbox ... file-delete`)。处理:**前台**申请无沙箱执行
(后台任务里解除沙箱不生效;`-skipMacroValidation`、改 `HOME` 都无效)→ `pkill -f swift-plugin-server` → 清 DerivedData。

## 2. 播放内核(libmpv)

**头文件是 `<mpv/...>`,不是 `<libmpv/...>`。** opengl-cb 自 0.33 已失效,`--wid` 在 macOS 不稳定,网上旧教程别照抄。

**每次 draw 都 `update()` + 无条件 `render()`。** 非 ADVANCED_CONTROL 下 `mpv_render_context_update()` 的 flags 从不置位,
拿它 gate `render()` 会死锁。要省掉重画同一帧,用 update 回调置标志、在 `canDraw` 把关(`MPVPlayer.needsRender`)。

**FBO 不能写死 0 ——「有声音、黑屏」。** `CAOpenGLLayer` draw 时绑的是 layer 自己的 FBO,每帧
`glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING)` 传给 mpv。mpv render 完会把绑定还原成 0,探针直接读会误判。

**渲染阻塞主线程:播放时界面和弹幕被压到视频帧率。** `CAOpenGLLayer` 的 `isAsynchronous` 模式由主线程定时器驱动、
draw 跑在主线程;`mpv_render_context_render` 默认 `BLOCK_FOR_TARGET_TIME = 1`,画完阻塞到上屏时刻。
做法:⛔ 不开 `isAsynchronous`,mpv 通知时在专用队列上 display(MPV_INTEGRATION.md §2);仍设 `video-timing-offset=0`
并每次传 `BLOCK_FOR_TARGET_TIME=0`。窗口被遮挡时 CA 不调 draw,采样取证要先确认窗口可见。

**`report_swap` 报过一次就得一直报。** 之后 VO 每帧都等下一次 swap,等不到 200 ms 就丢帧(`frame-drop-count` 涨)。
displayLink 停了没叫醒、或只在部分时候报,症状是画面一卡一卡而解码与声音正常(MPV_INTEGRATION.md §2.1)。

**画面偏移。** `MPVLayerView` 走 `makeBackingLayer`,渲染尺寸取 GL viewport,别让 `layout()` 把 layer 拽到父 layer 原点。

**认证头:`MPV_FORMAT_NODE` 数组,`mpv_initialize()` 之后、`loadfile` 之前设 `http-header-fields`。** 值里自带逗号。

**`track-list` 事件里的 `mpv_node` 归 mpv,⛔ 不得 `mpv_free_node_contents()`。** 会 talloc 断言(SIGABRT)。
必须同步解析完,节点只活到下一次 `mpv_wait_event()`。

**mpv 的轨道号不是 Emby 的 `MediaStream.Index`(Q21)。** `src-id` 从 1 起;`ff-index` 碰巧一致但不保证。
规则在 `StreamIndexMapper`:同类型内嵌轨按出现顺序对应;转码流、外挂轨、条数对不上 → 整键不报。

**设了 `aid` / `sid` 要读回。** 设了不存在的轨会变 `no`。

**`slang` 挑不出「简体中文」,用户的 `mpv.conf` 也不会被读(`config=no`)。** 中文偏好由客户端判(`SubtitlePreference`)。

**事件队列满了会静默丢事件。** 等帧 / 等结束的循环(测试、探针)要持续排空队列。

**事件线程的退出条件是独立的 `isStopping`,不是 `phase`。** 关窗时恰好来一个 END_FILE 会把 tearingDown 覆盖掉,
`shutdown()` 等满 5 秒 → UI 冻结。

**事件线程体不能强持有 self。** `Thread { [weak self] in self?.eventLoop() }` 会把 weak 提升为强引用一直持有;
每轮迭代取一次强引用、用完即弃。回归测试 `testPlayerDeallocatesWhenDroppedWithoutShutdown` 要先 sleep 0.2s。

**两把锁,锁序恒为 `renderMutex` → `mutex`。** 整帧 render 放进 `mutex` 会让主线程每次 pause/seek 都等一次 GPU 提交。

**播完不回到 `idle`(Q7)。** 一个 `MPVPlayer` 只播一个 URL,换台 = 销毁重建(复用会沿用上一轮的 `http-header-fields`,跨服务器串台)。
播完是事件不是状态,phase 可能停在 `.playing`,要看 `isEnded`。

**显示器休眠必须宿主自己持(Q34)。** `--stop-screensaver` 在 `vo=libmpv` 下不生效。`DisplaySleepAssertion` +
`PlayerViewModel.shouldPreventDisplaySleep`;`isolated deinit` 兜底,但持有者有引用环时 deinit 不跑,别绕开 `stop()`。

**`time-pos` 通知只有 3.4–3.6 次/秒。** 要更细的进度做插值。

**杜比视界发紫发绿 = legacy `gpu` 渲染器不处理 DV 的 RPU。** 解:render context 传
`MPV_RENDER_PARAM_BACKEND = "gpu-next"`(来自未合并的 draft PR mpv-player/mpv#16818,所以要自编 libmpv)。

**create 成功 ≠ gpu-next 生效。** 传不认识的后端名 mpv 静默回退且 `rc=0`。⛔ 别声称能检测静默回退;
要确证看日志 `Using gpu-next backend.` 或用真实 DV 片源看画面。

**⛔ 别在 `mpv_initialize()` 之前设 gpu-next 专属选项。** `MPVPlayer.init` 把任何 `mpv_set_option_string` 失败当致命,
legacy 后端不认识这些选项 → 连回退也崩。要加就 post-create 用 `mpv_set_property_string` 非致命设置。

**gpu-next 能耗爆表 = 硬解退成了 `videotoolbox-copy`(补丁 0003)。** PR 后端不注册 hwdec 设备,补丁注册 VT 设备 + IOSurface 映射;
① libplacebo 的 GL 后端采样不了 `GL_TEXTURE_RECTANGLE`,要先 `pl_tex_blit` 到 2D 纹理;② libplacebo 外调 GL 残留的错误码会被它下一次
`glGetError` 认领(看到 `pl_generate_blue_noise` 吃 CPU 就开 `libmpv_render=trace` 找第一条 GL 报错)。验收:统计「解码」是 `videotoolbox` 不是 `-copy`。

**draft PR 后端上下颠倒、闪烁(补丁 0001)。** `render()` 不读 `FLIP_Y`;参数零初始化 + 写死最近邻缩放。改用默认参数时同时
`frame_mixer = NULL`。翻转设目标**平面** `flipped`,⛔ 别翻 crop(OSD / 字幕不跟着翻)。

**换音频设备(连蓝牙耳机)崩溃 = `ao_coreaudio` 初始化失败时漏注销热插拔监听(补丁 0002)。** 之后任何设备变化回调读野指针。
复现不用真插拔:同进程建一个私有聚合设备即可。0002 用的是上游 #18383:失败统一走 `uninit`,而 `init_audiounit` 的失败
标签释放 unit 却不置空,`uninit` 会再释放一次 —— 补丁 0005 补上置空,换上游基线时要确认上游修了这里再删。

**改倍速卡顿 = 实际跑的是 `ao_avfoundation`(补丁 0004,Q43)。** macOS 27 上 `ao_coreaudio` 设 `ChannelMap` 必报 `-50`
(上游 #18384),mpv 静默回退 avfoundation;它预排约 2 秒按旧倍速拉伸的音频,改 `speed` 后音频时钟跳几秒,视频连续丢帧追。
排查先看 `current-ao`;拿 Homebrew mpv 对照时别加 `--ao=coreaudio`(初始化失败就没声音,反而看不出问题)。上游修好 #18384 后删补丁 0004。
上游修法未定:#18463(删掉这次调用)、#18637(改成 Output scope 的 `SInt32` 映射,已 approve)、#18679(同作者后提,删调用并修
立体声偏好映射)。IINA 自带的补丁走的是 #18637 那条路。macOS 27.2 内建扬声器上实测这次设置不再报错(只验了这一种设备)。

**补丁 0004 只把 `ChannelMap` 失败降为告警不够,必须丢掉那个 AudioUnit 重建。** 设映射被拒后的 unit `Start` 返回成功,
但渲染回调一次都不调 → 画面停在首帧、`current-ao` 却显示 coreaudio。排查「首帧出来就不动」先看 `time-pos` 是否推进。

**`NSWindow.isReleasedWhenClosed` 默认 YES。** 手动建窗口交给 ARC 时置 `false`,否则 `close()` 过度释放。

**测试媒体要 faststart(`-movflags +faststart`)。** moov 在尾部 + 服务器不支持 Range 时流不可 seek,首帧永不就绪。

**文件没加载好时,`seek` 命令一律返回 `-12`(`MPV_ERROR_COMMAND`)。** 分不出「还没加载好」和「流真不可 seek」:
`FILE_LOADED` 那一刻起才返回 0,播完(eof)后又回到 -12。`duration` 不能当「能 seek」用(百度源的时长在会话准备阶段就有)。
判据是内核里有文件(`PlayerViewModel.isReadyToSeek`);拖动失败⛔ 不能写进 `failure`(那是整页覆盖层,会压在正常播放的画面上)。

**回退超出身后缓冲就要重新拉流,缓冲预算不能只管前向(M2)。** `demuxer-max-back-bytes` 决定播放位置身后保留多少字节:
回退落在这段里是纯内存 seek,超出就重新请求;它与 `demuxer-max-bytes` 单位都是字节,折算成秒随码率变
(80 Mbps 下 128 MiB 只有约 13 秒),⛔ 不能拍固定值。`MPVCacheBudget` 按 `MediaSource.Bitrate` 标定两块预算
(取值、下限与上限见 `MPV_INTEGRATION.md` §3;码率缺失的合成源走下限),在 `mpv_initialize()` 之前设。

**沙盒 App 收不到 `open --args`,直接 exec 会 SIGTRAP。** 外部驱动只能靠 URL scheme;⛔ 不要加「播任意 URL」的 scheme(任何网页都能触发)。

## 3. Emby 接口

**没有 Direct Play。** `EnableDirectPlay` 固定 false;HTTP 拉原文件叫 Direct Stream。

**`URLComponents(string: "https://")` 的 host 是 `""` 不是 nil。** 要同时判 `!host.isEmpty`。

**`/Items/Latest` 返回裸数组(Q23)。** 手写 fixture 要照真实响应写,别按类推。

**「继续观看」两台服务器结论相反。** 4.9.5.0 上 `/Items/Resume` 不带参数恒 0 条;4.7.11.0 上 `/Items?Filters=IsResumable`
不带 `ParentId` 返回媒体库条目。照抄 Emby Web:`/Users/{uid}/Items/Resume?Recursive=true&MediaTypes=Video`。
⛔ 剧集页定位别换成 `Resume?ParentId=...`,它会把进度为 0 的集也返回。

**电影没封面(Q35)。** 电影常常只有 `ImageTags["Primary"]`;有的服务器把 Primary 的 tag 回填进
`BackdropImageTags` 但 Backdrop 实际 404。`EmbyItem.coverImage` + `coverImageFallback` 两级交给 `PosterImage`。

**`/Movies/Recommendations` 恒返回空,首页推荐用 `SortBy=Random`。** 它只按最近看过的电影算相似片,本地实例标了已看仍返回 `[]`;
`/Users/{uid}/Recommendations` 404;`/Items/{Id}/Similar` 要种子条目。
`Limit` 要大于轮播张数:hero 要求带背景图,而 `Movie` 常常只有竖版海报。

**`SortBy=Random` 的结果会被响应缓存钉住 1 小时 —— 有意为之,别去「修」。** 缓存 key 含完整 query,同一批「随机」在 TTL 内稳定;
换一批只在 ⌘R 与播放上报 Playing / Stopped 时(整台作废)。⛔ 别为此改 `isResponseCacheable` 或让推荐绕缓存。

**`/Shows/NextUp` 路径里没有 `{Id}`(Q25)。** 剧集页定位 = NextUp → 可续播 → 第一集。

**首页不放跨剧「下一集」行(Q31)。** 用户服务器上不带 `SeriesId` 会 400 `SeriesId is required`;剧集页带 `SeriesId` 的 NextUp 不受影响。

**DirectStream 403 来自跳转后的推流节点。** 部分服务器 `/videos/{id}/original.mkv` 回 301 跳到另一个 host,地址自带签名,
节点按 UA 白名单放行:在设置里填白名单播放器的 UA 后能播。ffmpeg 日志里只看得到最终的 403;
`PlaybackFailureProbe` 遇 4xx/5xx 会记下跳转目标并对它各探一次。

**禁用账户登录返回 403 不是 401。** 客户端显示「没有访问权限」,与真实原因不符;本地实例可复现。

**迟到的旧 token 401 不能删掉刚存的新 token。** 只删那次请求用的 token。

**可续播由服务端判定**(`MinResumePct` / `MaxResumePct` / `MinResumeDurationSeconds` 默认 120 秒)。客户端不复刻。

**本地实例的结论不能当真实服务器也成立。**

## 4. App 行为

**关窗后同一详情页再点播放从旧位置起播(Q22)。** 要等 Stopped 真正发完(`PlaybackProgressReporter.drain()`)再重读详情。

**编辑服务器地址后浏览仍用旧地址。** 凡是按 id 缓存了档案副本的对象(如 `AppContainer.connections`),
改档案的每条路径都要让缓存失效;地址变了要重新探测,探测不通不保存。

**倍速:上报要带当前值、滑块要合并上报、新建播放器要设回去。** 连续滑块一次拖动十几个请求 → `scheduleRateChangeReport()`
延后 0.5s 互相取消。转码 seek、下一集、重开都会新建播放器 → `PlaybackSpeedStore` 在起事件泵之前设回去;⛔ 不落 UserDefaults。

**「同一部剧沿用倍速」的键。** Emby 是「服务器 id + `SeriesId`」(电影退化成 Item Id);百度是「账号 + 剧目录」
(`BaiduPanPath.seriesDirectory`,跨季也跟得过去)。百度不是剧集时退化成 `fs_id`,否则同目录几部电影串台;
是不是剧集看 `episodeQueue`(随请求带进来),⛔ 别去等列网盘。

**播放有剧照的分集时崩溃。** `MPMediaItemArtwork` 的 `requestHandler` 写在 `@MainActor` 类型里继承了主线程隔离,
MediaPlayer 在别的队列调它 → `EXC_BREAKPOINT`。交给系统框架在任意队列回调的闭包,在 `nonisolated static` 方法里创建。

**全屏无效(Q19)。** `Window` 场景的 `collectionBehavior` 是 `.fullScreenAuxiliary`;`WindowBox` 每次切换前设为 `.fullScreenPrimary`。

**首页 hero 轮播不会让首屏跳。** 高度按窗口宽度算定值,文字与按钮全是 overlay;代价只有图片请求,靠只轮几张 + 预取下一张按住。

**缓存:登录验证必须绕过缓存**(否则失效 token 假装登录成功);写操作作废整台缓存时,之前发出的读请求回来仍会写旧数据 →
per-server epoch;Progress 每 10 秒一次,不能触发失效。图片内存缓存用 LRU,别超限全清(会让另一台服务器的海报陪葬)。

**单元测试跑在宿主 App 进程里,共享沙盒容器。** 诊断日志要挡测试进程,否则一次全量测试冲掉真实排障记录。

**控制栏自动隐藏是两条规则:「静止 2 秒」和「指针移出窗口 0.3 秒」。** 只做移出那条,播放中移动鼠标后就再也不收。

**`Task.cancel()` 拦不住已经过了 `sleep` 的任务。** 延时任务的取消要同时给一道代次门(转码 seek 合并用 `restartEpoch`)。
`isRestarting = true` 要写在 `stop()` 之后。

**系统工具栏的坑(Q37)。** `.searchable` 挂在 `NavigationStack` 外面就不出现;原生全屏下工具栏背景去不掉(系统把它搬进
`NSToolbarFullScreenWindow`,相关修饰符都不生效)。所以主窗口不让系统建工具栏(`.hiddenTitleBar`、不声明 `.toolbar`、
push 页 `.navigationBarBackButtonHidden(true)`),顶栏自绘(`BrowseChromeBar.swift`)。

**`.hiddenTitleBar` 窗口上 ⛔ 别用 `.toolbar(.hidden, for: .windowToolbar)`:红绿灯会一起消失。** 它隐藏的是标题栏容器,
按钮本身 `isHidden == false`,只查按钮查不出来。push 页带系统返回按钮时 SwiftUI 会建 NSToolbar,红绿灯被挪进工具栏带。

**共用的「刷新」靠各页 `.task(id:)` 吃 `refreshToken`(Q36)。** 每个新页面都要确认接上了。

**同类型来源之间切换不重建页面,`@State` 的 ViewModel 还是上一个的。** 根页要按来源 id 重建(`.id(source.id)`);
以后加「一个来源一份状态」的页面同理。

**`.sheet(item:)` 的内容里 ⛔ 别用 `if let` 去取第二个 `@State`。** 内容闭包在状态提交前就被求值,第一次弹出的是空白面板。
做法:把要用的东西装进同一个 `Identifiable` 载荷(如 `RenameRequest`),`id` 用 `UUID`(用 `fs_id` 时连改两次同一目录会复用旧 `@State`)。

## 5. 工具与环境

**沙盒 App 写不了 `~/Library/Logs`。** 诊断日志在容器里(路径见 `CLAUDE.md`);系统日志
`/usr/bin/log show --last 10m --predicate 'subsystem == "com.local.LumaPlayer"' --info`(zsh 里裸 `log` 是内建命令)。

**本机 `grep` 可能是 rg 的别名。** 用 `/usr/bin/grep`。BSD `grep -E` 不支持 lookahead。

**Docker Desktop for macOS 不支持 `network_mode: host`**,CLI 常不在 PATH。本地实例的其他坑见 `Tools/emby-dev/README.md`。

**读异步落盘的日志要轮询等标志行出现,不要固定 sleep。**

## 附:其余已结案编号

| 编号 | 一句话 |
|---|---|
| Q4 | 图标由 `Tools/app-icon/render-icon.swift` 绘制,改脚本重跑,不手改 PNG |
| Q5 / Q8 | 真实服务器都不是自己的 →「禁用转码的服务器」构造不了,用本地实例与 mock |
| Q9 | `SecretRedactor` 脱敏 `api_key=`、`X-Emby-Token`、整行 `Authorization`、JSON 里的 `Pw` / `Password` |
| Q10 | 登录体 `{"Username", "Pw"}` 与 `/System/Info/Public` 免认证已在 4.7.11.0 实测;不做小写 `pw` 重试 |
| Q43(季号) | `S0` / `Season 0` / `第0季` 认季号 **0**(特别篇,`TMDB_API.md` §7);季文件夹分支不套 `looksLikeEpisodeSequence` 闸门,套了会把剧名认成季文件夹名 |
