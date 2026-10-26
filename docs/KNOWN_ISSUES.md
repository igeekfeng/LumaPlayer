# 未决问题与待验证清单

> 不确定、不能猜、或缺外部条件才能核实的事登记在这里,不要只写 `// TODO`。
> 编号 `Qnn` / `M2` / `M4` 被代码注释引用;结案后挪到 `PITFALLS.md`(写一句结论)或直接删掉。
> 新条目格式:问题 → 现在怎么处理 → 结案还缺什么。

## A. 要真实服务器才能核实的接口行为

只实测过一台真实服务器 **4.7.11.0**;本地实例 4.9.5.0 的结论不算。核实一律只读、低频、单次。

- **Q11 其余服务器的版本未知。** 结案:`curl -s '<地址>/emby/System/Info/Public' | grep -o '"Version":"[^"]*"'`。
- **Q12 图片端点要不要认证头;`/Users/{uid}/Items` 是否正式支持 `SearchTerm`。** 现在图片一律带头(只经 `PosterImage`);
  `SearchTerm` 官方只列在 `/Search/Hints`,4.9.5.0 可用。结案:4.7 上对同一张图带 / 不带头各请求一次;搜一个词。
- **Q13 `PrimaryImageTag` 与 `ImageTags["Primary"]` 以哪个为准。** 两个都解,后者优先。无害,不急。
- **Q14 混合媒体库(`CollectionType == null`)只显示 `Movie,Series`。** 未在任何混合库上验证。
- **Q15 `MediaSource.LocationType` / `VideoType` 官方 OpenAPI 里没有。** 不解;要按 DVD / ISO 区分前先核实。
- **Q17 `baseURL` 带子路径(反代)时,转码 URL 可能丢掉那一段。** `transcodeURL` 用 `URL(string:relativeTo:)`,以 `/` 开头会替换整个 path。
  服务端的 `TranscodingUrl` 是否已含子路径未知,两种修法互斥,⛔ 不得「两种都试」。结案:配了反代子路径的实例上看 `TranscodingUrl` 形态。
- **Q20 转码 seek 的「停流」只是断开连接 + 发 Stopped。** 服务端 ffmpeg 未必立刻退出。结案:连续拖几次看 Dashboard 转码进程是否回落。
- **Q24 搜名字中间的字搜不到。** 4.9.5.0 上只能词首匹配,Emby Web 同样搜不到,是服务器侧。结案:拿到「别的播放器能搜到」的具体场景再对照。
- **Q27 4.7 上 `/Items/Resume?Recursive=true&MediaTypes=Video` 是否正常。** 若反而变空,先去掉 `MediaTypes`。
- **Q28 4.7 上 `Filters=IsResumable` 带 `ParentId` 是否生效。** 剧集页定位「NextUp → 可续播 → 第一集」的第二步依赖它;
  若被忽略会静默定位到「最近播放的集」。同理媒体库筛选不提供「可续播」。结案:4.7 上进一部看了一半的剧。
- **Q30 片头 / 片尾标记从没在任何服务器上见过。** 只见过 `Chapter`(片头检测要 Premiere,片尾靠插件)。全部按可选处理。
- **Q33「移出继续观看」(`HideFromResume`)只在 4.9.5.0 上验证。** 4.7 上若 404,菜单项会报错回滚但功能等于没有。
  ⛔ 不要在别人的服务器上真的移出条目,只确认端点存在。
- **Q39 播放上报 `SubtitleOffset` 单位未知。** 官方只写「floating point value」。Erika 没有字幕延迟,客户端现在没有可报的值;
  将来恢复字幕延迟时先核实:本地实例上用 Emby Web 调一次字幕偏移,看 `Progress` 请求体里的值与「秒」的关系。

## B. 已实现、未视觉 / 实机确认

本机能截图但没有辅助功能权限,需要交互的画面要人来操作。确认一项删一项。

| 项 | 怎么确认 |
|---|---|
| 下一集提示:无片头标记时结束前 10 秒出现,倒计时结束自动换集,取消后不再出现 | 播一集拖到片尾 |
| 起播自动选中简体(其次繁体)中文字幕;只有英文轨时不动 | 播带中文字幕轨的片子,看「字幕」菜单勾选 |
| 统计 overlay(I):播放方式 / 视频 / 色彩 / 解码 / 视频码率 / 音频 / 帧 / 输出 / 显存;给不了的字段整行不显示;没有缓冲 / 缓存 / 网络行 | 播放时按 I |
| 进度条只剩轨道底色 + 已播放段;悬停时间气泡、右侧「剩余 / 预计结束」切换正常 | 播放时悬停进度条 |
| 控制中心「正在播放」的封面、上一曲、倍速 | 播放时开控制中心 |
| 窗口置顶(⌥⌘T);触控板双指横滑拖进度,纵向不被拦截 | 播放窗口里试 |
| 深浅色、「减少透明度」「减少动态效果」下的控制栏与详情页播放按钮 | 系统设置切换后看 |
| 详情页头部(非全屏):无工具栏背景色、无服务器切换,hero 图透到标题栏下 | 打开任一详情页 |
| 凭据从钥匙串迁到文件:首次启动弹「服务器数 + 1」次授权窗,之后不需重登、后台不多设备,再部署不再弹窗 | 装新版后首次启动 |
| 播放中不息屏:显示器休眠设 1 分钟连播 5 分钟不息屏,暂停后正常息屏 | `pmset -g assertions` 看 `PreventUserIdleDisplaySleep` |
| **Q37** 控制栏改版:亮画面下压暗衬底够不够、播放头尺寸、640pt 窄窗口挤不挤、自动隐藏 2s / 0.3s 是否顺眼、长剧名截断、「21:35 结束」宽度、转码下连点前后跳的 0.25s 合并是否无感 | 有可播媒体时亮 / 暗场各截一次 |
| **Q40** 字幕外观:字号 / 颜色 / 粗体 / 描边 / 描边+阴影 / 底框三选一的实际效果,ASS 强制套用后排版,转码 seek 后外观保持,播放中改即时生效 | 播同时有 SRT 与 ASS 的文件 |
| 设置窗口 560×420 下四个标签页排版;「播放」页有「神经网络超分(ArtCNN)」开关;「字幕」页没有垂直位置 / 底框不透明度;改步长后方向键与前后跳按钮图标跟着变 | ⌘, 打开截图 |

## C. 缺外部条件的验收

### Q16 真实服务器上的播放验收

都没有留下真实服务器上的验证记录:

- [ ] DirectStream 能播(统计里显示「直接串流」)
- [ ] 转码能播,**拖动进度可用**
- [ ] 多音轨 / 多字幕切换正确,上报的 `AudioStreamIndex` / `SubtitleStreamIndex` 与 Emby 一致
- [ ] 关窗后 Emby Web 端进度正确
- [ ] 两台服务器之间切换不串台(进度、续播、图片)
- [ ] token 被吊销后回登录页 / 静默重登(⛔ 不去别人后台删设备制造 401)

本地实例不发 `DeviceProfile` 时对 HEVC 10bit 也给 DirectStream,所以**转码路径在本地也跑不起来**。

## D. 工程

- **M2 HTTP 预读 / 回看缓存未按真实码率标定。** 现为 128 / 64 MiB(`ERIKA_INTEGRATION.md` §6.1),4K remux(~80 Mbps)下约 13 秒。
  只在本机限速服务器 + 合成文件上测过。高码率远程流仍频繁缓冲再按 `MediaSource.Bitrate` 动态算。
- **Q32 中文简繁判定只在合成用例上跑过。** 关键词表(`zh-Hans` / `chs` /「简体」/ `Simplified` …)没见过真实资源。
  只标 `chi` / `zho` 的轨排第三档;判不出不动。结案:找一部同时有简繁轨的片子,记下 language / title 原文回填单测。
- **M4 外挂字幕(带认证的远程字幕 URL)未实现。** 要做先实测 Erika 怎么加外挂字幕、headers 怎么传。

## E. Erika 待真机核实

全部 🔶。核实后只改 `Core/Erika/`(`ErikaPlaybackEngine.swift` / `EofDetector.swift` 顶部有同一份清单),回填这里与 `ERIKA_INTEGRATION.md`。

| 编号 | 未知 | 怎么核实 |
|---|---|---|
| Q43 | 自然播完落在 `stopped` 还是 `closed`;是否总先来一次到末尾的 `positionChanged`(若不来,播完会被判成 `.stopped`,下一集与收尾上报不触发) | 播一部片子到自然结束,看是否走 `.eof` |
| Q44 | `ErikaVideoView` 是否自己 attach / resize;`open` 是否要求先 attach(现在先上屏再 open) | 观察首帧黑屏 / resize |
| Q45 | `setVolume(0)` 是否完全静音;音量 / 倍速在 `open` 后、`play` 前设置是否被接受 | 播放中静音 / 还原、改倍速 |
| Q46 | `setSubtitleScale` 与 `setSubtitleStyle` 的叠加关系;Erika 字幕默认值是否等于 `ErikaSubtitleStyle()` 初值 | 分别只调 scale、只调 style、两者同调 |
| Q47 | `tracks()` 是否填 `selected`;其 id 与 `trackSelection()` 是否同一套 | 开字幕 / 音轨菜单,多切几次 |
| Q48 | 统计语义:「迟到丢帧」(快照 `lateDroppedFrames`,内核渲染处计)与肉眼卡顿是否吻合、渲染器显存当「显存」、色彩枚举码映射是否完整 | 4K 高码率片源播放中开统计面板,对照活动监视器与内核文档 |
| Q49 | `setUpscaler` 能否播放中切换(现在只在建引擎时设) | 播放中调用看是否生效 |
| Q50 | `outputMode = .automatic` 是否合适;`edrHeadroom` 取值;HDR 片源亮度 / 色彩 | 播一部 HDR 片源 |
| Q51 | Erika 实际是静态还是动态 framework、有无嵌入产物要签名;`disable-library-validation` 还要不要 | 检查 `.app` 内嵌二进制 + `codesign -d --entitlements` |
| Q52 | Metal 渲染 + 33 ms 主线程轮询在 4K 高码率下是否掉帧 | 统计面板掉帧 + 活动监视器 |
| Q53 | `ErikaError.statusCode` 各取值含义(能否给更准的失败提示) | 构造 404 / 断网 / 不支持格式 |

### Q54 起播时 `ErikaPlayer.open()` 在主线程同步探测,整个 App 卡住

- `erika.h`:`open() synchronously probes streams`;`ErikaPlayer` 是 `@MainActor`,探测期间的网络往返(HEAD + 首段 Range,MP4 还要取尾部 moov)全在主线程。0.3.0 仍是同步 open。
- 本机限速服务器实测(未在真实服务器验证):80 ms 往返 → 0.8–0.9 s;200 ms → 1.1–1.4 s;偶发 4.8 s。
- 没直接修:挪出主线程要么绕过 SDK 的 `@MainActor` 隔离(违反硬规则 3),要么自己封装 C 句柄(非线程安全,渲染回调也在主线程用同一个句柄)。
- 出路:等 / 请求上游提供异步 open;或由维护者决定是否为此开例外。

### Q55 进度条无法显示「已缓冲到哪里」

Erika 0.2.1 只有 `bufferingChanged` 一个布尔量,`erika.h`、presenter 统计、`invoke_json` 方法表里都没有已缓冲时长 / 区间。
0.3.0 的诊断快照 `buffers.playback` 只有包 / 帧队列深度,`playback.buffering` 只记缓冲时长,仍没有「缓冲到哪个时间点」。
⛔ 不用码率 × 时间估一个假缓冲条(硬规则 4)。上游提供后再接,接入点在 `ErikaPlaybackEngine` + `PlayerEvent`。
