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
脚本默认从 `Vendor/mpv/prebuilt/libmpv-bundle.tar.gz` 还原(校验 sha256 + 解压 + 重定位 install name +
逐个 ad-hoc 重签),只用 `/usr/bin` 系统工具,不需要 Homebrew / meson / ninja / pkg-config。
还原后的 prefix 自带 50 个 dylib(libmpv 本体 + 49 个传递依赖),Debug 运行与测试只读这里,
`brew upgrade` 改的是别处的库,动不到它。
mpv 源码改动只能写成 `Vendor/mpv/patches/*.patch`(`--from-source` 里 `reset --hard` 后按序 `git apply`)。
升级内核:维护机 `--from-source` 重编 → `--pack` 重新固化 → 提交 `Vendor/mpv/prebuilt/` 下三个文件。
固化产物进仓库,⛔ 不能带本机路径(用户名):mpv 把 `meson.build_options()` 原样编进库,⛔ 不给 meson 传带路径的 `-D`;
Swift 模块的 N_AST stab、tar 头的属主也会带用户名。对策写在 `build-libmpv.sh` 源码模式的注释里,
`--from-source` 与 `--pack` 都按原始字节扫 `$HOME`,命中即失败(`strings` 扫不到符号表,不能用它判)。

**打包脚本只对 Release 产物跑,且只作用于拷出来的 App。** Debug 产物是桩 + `LumaPlayer.debug.dylib`,
从桩遍历 `otool -L` 会漏依赖;打包时要删指向依赖根的 `LC_RPATH`。
重签名一步别用 `> >(...)` 进程替换:命令行沙箱会拦 `/dev/fd`,用临时文件收 stderr 再 `grep -v`。

**脚本必须用物理路径解析仓库根。** 二进制里的 libmpv 路径是编译器的物理路径;从软链或大小写不同的路径调用时,
`pwd` 拿到的逻辑路径对不上,`bundle-libmpv.sh` 一条依赖都匹配不到、`Frameworks/` 空着。
做法:`REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"`(`pwd -P` 不改大小写,不够)。

**只支持 macOS 27。** 固化产物按 27.0 编译,Deployment Target 低于 27 会有链接器 warning 且产物也只能在 27 上跑(Q3、Q26)。

**`swift-plugin-server produced malformed response`,`@Observable` / `@State` 宏全线报错** —— 不是代码问题,是宏服务。
常见诱因:命令行沙箱拦了 `~/.swiftpm/security`(stderr 只有 `sandbox ... file-delete`)。处理:**前台**申请无沙箱执行
(后台任务里解除沙箱不生效;`-skipMacroValidation`、改 `HOME` 都无效)→ `pkill -f swift-plugin-server` → 清 DerivedData。
`pkill` + 清 DerivedData 后仍报 `sandbox-exec: sandbox_apply: Operation not permitted` 时,给 xcodebuild 加
`SWIFT_DISABLE_SANDBOX=YES OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` 可编译通过。
⚠️ 测试阶段还可能 `The test runner hung before establishing connection`(host app 起不来);
这时单独跑 `xcodebuild ... build` 只确认编译结果,⛔ 不能把「编译过了」说成「测试跑过了」。

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

**挂事件桥之前的属性变化事件不能丢。** 事件线程在 `MPVPlayer.init` 末尾就在取事件,而起播倍速 / 音量 / 字幕延迟是在
挂桥之前设的:变化事件先于桥到达,丢掉后 mpv 不再变化就不会重发,ViewModel 的读回值一直停在默认值。症状是记过 1.5×
的剧起播后控制栏显示 1×、弹幕每 1.2 秒往前瞬移约 0.5 秒(弹幕时钟按 1× 外推,而按相邻位置更新算出的速率是 1.5)。
做法:桥没挂时把事件积在 `eventsBeforeBridge`,`attach(eventBridge:)` 在锁内按序补发(`MPVEventBridgeAttachTests`)。

**两把锁,锁序恒为 `renderMutex` → `mutex`。** 整帧 render 放进 `mutex` 会让主线程每次 pause/seek 都等一次 GPU 提交。

**播完不回到 `idle`(Q7)。** 一个 `MPVPlayer` 只播一个 URL,换台 = 销毁重建(复用会沿用上一轮的 `http-header-fields`,跨服务器串台)。
播完是事件不是状态,phase 可能停在 `.playing`,要看 `isEnded`。

**显示器休眠必须宿主自己持(Q34)。** `--stop-screensaver` 在 `vo=libmpv` 下不生效。`DisplaySleepAssertion` +
`PlayerViewModel.shouldPreventDisplaySleep`;`isolated deinit` 兜底,但持有者有引用环时 deinit 不跑,别绕开 `stop()`。

**`time-pos` 通知只有 3.4–3.6 次/秒。** 要更细的进度做插值。

**杜比视界发紫发绿 = legacy `gpu` 渲染器不处理 DV 的 RPU。** 解:render context 传
`MPV_RENDER_PARAM_BACKEND = "gpu-next"`(来自未合并的 draft PR 16818,所以要自编 libmpv)。

**create 成功 ≠ gpu-next 生效。** 传不认识的后端名 mpv 静默回退且 `rc=0`。⛔ 别声称能检测静默回退;
要确证看日志 `Using gpu-next backend.` 或用真实 DV 片源看画面。

**⛔ 别在 `mpv_initialize()` 之前设 gpu-next 专属选项。** `MPVPlayer.init` 把任何 `mpv_set_option_string` 失败当致命,
legacy 后端不认识这些选项 → 连回退也崩。要加就 post-create 用 `mpv_set_property_string` 非致命设置。

**gpu-next 能耗爆表 = 硬解退成了 `videotoolbox-copy`(补丁 0003)。** PR 后端不注册 hwdec 设备,补丁注册 VT 设备 + IOSurface 映射;
① libplacebo 的 GL 后端采样不了 `GL_TEXTURE_RECTANGLE`,要先 `pl_tex_blit` 到 2D 纹理;② libplacebo 外调 GL 残留的错误码会被它下一次
`glGetError` 认领(看到 `pl_generate_blue_noise` 吃 CPU 就开 `libmpv_render=trace` 找第一条 GL 报错)。验收:统计「解码」是 `videotoolbox` 不是 `-copy`。

**draft PR 后端上下颠倒、闪烁(补丁 0001)。** `render()` 不读 `FLIP_Y`;参数零初始化 + 写死最近邻缩放。改用默认参数时同时
`frame_mixer = NULL`。翻转设目标**平面** `flipped`,⛔ 别翻 crop(OSD / 字幕不跟着翻)。

**换音频设备(连蓝牙耳机)崩溃 = `ao_coreaudio` 初始化失败时漏注销热插拔监听。** 之后任何设备变化回调读野指针。
复现不用真插拔:同进程建一个私有聚合设备即可。上游的修法是失败统一走 `uninit`,而 `init_audiounit` 的失败标签释放 unit
却不置空,`uninit` 会再释放一次 —— 补丁 0005 补上置空,换基线时确认上游修了这里再删。

**改倍速卡顿 = 实际跑的是 `ao_avfoundation`(Q43)。** `ao_coreaudio` 把 `AudioChannelLayout` 传给
`kAudioOutputUnitProperty_ChannelMap`(要的是 `SInt32` 数组)时,macOS 27 上这次调用报 `-50`(不是每台设备都报),
mpv 静默回退 avfoundation;它预排约 2 秒按旧倍速拉伸的音频,改 `speed` 后音频时钟跳几秒,视频连续丢帧追。
v0.42.0 起上游已删掉这次误用;回归时排查先看 `current-ao`;拿 Homebrew mpv 对照时别加 `--ao=coreaudio`
(初始化失败就没声音,反而看不出问题)。

**补丁 0000 新增文件,`git reset --hard` 清不掉。** 构建脚本 reset 后必须 `git clean -fdx`,否则第二次运行 apply 报
`already exists in working directory`。

**HTTPS 流播不了先看 libmpv 链的是哪个 libcurl(MPV_INTEGRATION.md §3.4)。** `otool -L` 应是 `/usr/lib/libcurl.4.dylib`。
日志 `[curl] TLS certificate verification failed.` = 证书真的不被系统信任,⛔ 不要用 `tls-verify=no` 绕。

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

**闭包不要直接存进泛型 `Synchronization.Mutex`。** 现象:播放约十分钟后 VO 线程 `EXC_BAD_ACCESS (SIGBUS)`,
`KERN_PROTECTION_FAILURE` 落在 Stack Guard,栈顶是 `MPVGLLayer.scheduleDisplay` 与一串
`reabstraction thunk`。原因:`Mutex<(() -> Void)?>` 的 `withLock { $0 }` 在 inout 回写时把存着的闭包再包一层
重抽象 thunk(Release 下同样),每读一次调用链长一截;mpv update 回调每帧读一次,每帧多 64 字节栈,
512 KB 的 VO 线程栈约 8000 帧耗尽。做法:闭包先包进 `Sendable` struct 再进 `Mutex`(`RenderRequest.Handler`),
`MPVRenderGateTests.testFrameReadyCallbackDepthStaysFlat` 守着。

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

**倍速:上报要带当前值、连续调节要合并上报、新建播放器要设回去。** 连续调十几个请求 → `scheduleRateChangeReport()`
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

## 5. 网盘源的文件列表

**浏览页一页 100 条,⛔ 不取接口上限 1000。** 接口上限是「必须一次拿整层」时按次计费少发请求的口径;
一页给多少条按「用户看多少」定。每页都连带 `filemetas`(按 100 个 `fs_id` 一批串行打)、
对累计整套重跑 TMDB 刮削与 `compose`,一页 1000 条 = 首屏 10 次 `filemetas` + 整套重算。

**分页的推进量要用「服务端口径」,⛔ 不能用「本页实际拿到的条数」。**
百度 `list` 的条目里可能有缺 `path` / `fs_id` 的(解码时丢掉),115 的条目里可能有缺 `cid` 的
——那些条目**服务端照样推进了页**。用本页条数推进 → 漏项。
⇒ 百度是 `start + limit`,115 是 `offset + limit`(服务端回显的 `offset` + 我们请求的 `limit`)。

**百度的 `method=list` 拿不到总数** —— 响应里既无 `total` 也无 `has_more`(那两个是 `method=listall` 的字段)。
⇒ 「还有没有下一页」只能靠「这一页不满」推断;UI ⛔ 不能显示「共 N 项」。
115 的 `count` **是目录总条目数**,能精确判断 —— 两家判据不同,⛔ 不要互相套用。
详见 `BAIDU_PAN_API.md` §7.2 与 `PAN115_API.md` §3.1。

**115 的 `count` 是「当前查询条件下」的总数**,`show_dir` / `nf` / `type` 会改变它;
且它在翻页期间**会变**。⇒ 翻页总数与翻页请求要用同一套查询参数。

**115 的 `offset` 越界会静默回绕**(aps 接口文档原文:「相当于 `offset=0`,从头开始」),
服务端**不报错**。⇒ 用服务端回显的 `offset` 推进;服务端不认我们请求的 offset 时就停,
⛔ 不继续翻(否则同一页反复取)。

**合成必须拿累计的整套文件,⛔ 不能只给一页。** `BaiduPanMetadataSynthesizer` 靠整套判断
「成串的集号」(同目录 ≥2 个集号型文件)并配对同目录封面(`poster.jpg`)。
只给一页会把 `01.mp4` 判成电影,封面也配不上(封面文件可能在后面的页)。

**翻页失败⛔ 不清空已显示的内容**(同 Emby 侧 `PagedItemList`):页脚给「重试」,网格照旧。

**翻页前要作废在飞的刮削。** 刮削回来时执行 `items = enriched`(只有那一轮的条目),
会把刚加载完的下一页顶掉。

**重新 `compose` 出来的条目 `durationSeconds` 恒 nil。** 回填时长时若只填「本次请求到的」,
**已加载的条目会集体丢时长**(UI 读的是 `items[].durationSeconds`,⛔ 不是 `durations` 字典)。
⇒ 本次没取到就用上一轮的值兜底。

**判定为「剧」之后要把这一层列全。** 平铺存法的分集清单就是这一层的内容 ——
只列第一页的话「共 N 集」不准、第 N+1 集之后列不出来(剧详情页没有翻页入口)。
剧集目录的条目数通常远小于普通目录,这次全量读取换来的准确性值得。

**形态判定要跟着翻页重判。** 判定靠整套文件(「成串的集号」要同目录 ≥2 个),
第一页可能不足以判定 —— 前 1000 个是电影、后 200 个是集号型文件时,
第一页判成「普通目录」,第二页到了就该改成「剧」。不重判就会出现
「形态是普通目录、卡片却是剧集样式」的矛盾。

**后台刷新只取第一页 ⇒ 不能无条件覆盖当前状态。** 用户若已经翻到第 N 页,
直接覆盖会让已加载的页凭空消失、页脚重新出现(来回抖动)。
⇒ 只在「还停在第一页」时整体替换,否则只把新的封面 / 时长补到已有条目上。

**115:服务端没回显 `offset` 时,⛔ 不能当成「它不认」。**
「没回显」= **无法证伪**,不是「证伪」——当成不认会让浏览页永远停在第一页
(目录明明有 3000 条,界面只显示 1000 条,⛔ 还不报错)。
只有「回显了但与请求不符」才是确凿的异常。
⇒ 回绕的防护靠**内容重复**那道闸(累计时按 `fs_id` 去重),⛔ 不靠「必须回显」。

**落盘缓存复原出来的翻页游标 = 已有条数。** 百度 `start` 就是「跳过前 N 条」,
而服务端是**先全目录排序再切片** ⇒ 列到第 N 条,下一页的起点就是 N。
老版本写的缓存也是这个口径(自动翻页到不满一页为止),
即便目录大到被 `maxPages` 截断,截掉的也是**尾部**,⛔ 不影响前面条目的位置。
⇒ ⚠️ 别因为「老缓存可能被截断」就把偏移量设成 0:那会让翻页反复取第一页,
中间那段永远列不出来。

**翻页的「在飞」标志要无条件复位。** 它只表示「这一轮在飞」——
按 generation 条件复位的话,翻页途中切了目录就永远停在 true,
那一格再也不会被清,整个来源从此翻不了页(重载也不救)。

**删掉一条要把翻页状态里的那一条**剔除**,⛔ 不是把整个状态丢掉。**
丢掉整个状态会让 `hasMoreItems` 变 false → 页脚消失 → 用户以为目录就这些,
而这一层其余几百条还在屏幕上、却再也翻不出后面的页。游标不动(删一条不改变服务端的位置)。

## 6. 工具与环境

**沙盒 App 写不了 `~/Library/Logs`。** 诊断日志在容器里(路径见 `CLAUDE.md`);系统日志
`/usr/bin/log show --last 10m --predicate 'subsystem == "com.local.LumaPlayer"' --info`(zsh 里裸 `log` 是内建命令)。

**本机 `grep` 可能是 rg 的别名。** 用 `/usr/bin/grep`。BSD `grep -E` 不支持 lookahead。

**Docker Desktop for macOS 不支持 `network_mode: host`**,CLI 常不在 PATH。本地实例的其他坑见 `Tools/emby-dev/README.md`。

**读异步落盘的日志要轮询等标志行出现,不要固定 sleep。**

## 附:其余已结案编号

| 编号 | 一句话 |
|---|---|
| Q4 | 图标由 `Tools/app-icon/render-icon.swift` 生成 `AppIcon.icon`,改脚本重跑,不手改 `.icon` 里的文件 |
| Q5 / Q8 | 真实服务器都不是自己的 →「禁用转码的服务器」构造不了,用本地实例与 mock |
| Q9 | `SecretRedactor` 脱敏 `api_key=`、`X-Emby-Token`、整行 `Authorization`、JSON 里的 `Pw` / `Password` |
| Q10 | 登录体 `{"Username", "Pw"}` 与 `/System/Info/Public` 免认证已在 4.7.11.0 实测;不做小写 `pw` 重试 |
| Q43(季号) | `S0` / `Season 0` / `第0季` 认季号 **0**(特别篇,`TMDB_API.md` §7);季文件夹分支不套 `looksLikeEpisodeSequence` 闸门,套了会把剧名认成季文件夹名 |
