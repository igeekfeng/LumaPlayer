# 未决问题与技术约束

> 代码注释里的 `Qnn` / `Mnn` 编号指向这里的条目:记的是「现在为什么这么写」
> 与仍然成立的不确定性,不是任务进度。条目被推翻时直接改代码与这里的说明,不写修改记录。

## A. 接口行为与跨版本差异

只实测过一台真实服务器 **4.7.11.0**;本地实例 4.9.5.0 的结论不外推。核实一律只读、低频、单次。

- **Q11 其余服务器的版本未知。**
- **Q12 图片端点要不要认证头;`/Users/{uid}/Items` 是否正式支持 `SearchTerm`。** 图片一律带头(只经 `PosterImage`);
  `SearchTerm` 官方只列在 `/Search/Hints`,4.9.5.0 可用。
- **Q13 `PrimaryImageTag` 与 `ImageTags["Primary"]` 以哪个为准。** 两个都解,后者优先。
- **Q14 混合媒体库(`CollectionType == null`)只显示 `Movie,Series`。**
- **Q15 `MediaSource.LocationType` / `VideoType` 官方 OpenAPI 里没有。** 不解;要按 DVD / ISO 区分前先核实。
- **Q17 `baseURL` 带子路径(反代)时,转码 URL 会丢掉那一段。** `transcodeURL` 用 `URL(string:relativeTo:)`,以 `/` 开头会替换整个 path。
  服务端的 `TranscodingUrl` 是否已含子路径未知,两种修法互斥,⛔ 不得「两种都试」。
- **Q20 转码 seek 的「停流」只是断开连接 + 发 Stopped。** 服务端 ffmpeg 未必立刻退出。
- **Q24 搜名字中间的字搜不到。** 4.9.5.0 上只能词首匹配,Emby Web 同样搜不到,是服务器侧。
- **Q27 4.7 上 `/Items/Resume?Recursive=true&MediaTypes=Video` 是否正常。** 若反而变空,先去掉 `MediaTypes`。
- **Q28 4.7 上 `Filters=IsResumable` 带 `ParentId` 是否生效。** 剧集页定位「NextUp → 可续播 → 第一集」的第二步依赖它;
  若被忽略会静默定位到「最近播放的集」。媒体库筛选因此不提供「可续播」。
- **Q30 片头 / 片尾标记从没在任何服务器上见过。** 只见过 `Chapter`。全部按可选处理;兜底是播放页手动标注
  (`ManualMarkersStore`,同剧共用,覆盖服务端标记)。
- **Q33「移出继续观看」(`HideFromResume`)只在 4.9.5.0 上见过。** 4.7 上若 404,菜单项会报错回滚。
  ⛔ 不要在别人的服务器上真的移出条目。
- **Q39 播放上报 `SubtitleOffset` 单位未知,字幕延迟不上报。** 字幕延迟只在客户端生效(mpv `sub-delay`)。
- **Q50 批量标记(API_CONTRACT.md 5.8)。** Emby 无批量端点,整季 = 逐条串行写(20 集 = 20 个请求),无退避重试。
- **Q51 `ProviderIds.Tmdb` 的实际形态(API_CONTRACT.md 3.4.1)。** 按小写键兼容 `Tmdb` / `tmdb`;
  是作品级还是单集级 ID 未知(`search/episodes?tmdbId=` 要作品级)。若是单集级,弹幕降级层要先取 `SeriesId` 再读剧的 `ProviderIds`。
- **Q52 弹幕指纹的 16 MiB `Range` 请求(`DANMAKU.md` §3.1)。** `stream?static=true` 回 200 时拒绝、退回文件名匹配;
  认证头是否被接受、慢速服务器上「正在匹配」停多久都未知。

## B. 已实现、按设计处理的行为

下列条目解释代码现在怎么处理;改动这些地方时按括号里的编号回看上面的约束。

| 项 | 处理 |
|---|---|
| Q6 `hwdec-current` 实际解码器 | 统计面板「解码」直接读回 |
| 下一集提示 | 无片头标记时结束前 10 秒出现,倒计时结束自动换集,取消后不再出现 |
| 起播字幕选择 | 自动选中简体(其次繁体)中文字幕;只有英文轨时不动 |
| 缓冲显示 | 缓冲百分比 / 网速 / 进度条已缓存段 |
| 控制中心「正在播放」 | 封面、上一曲、倍速 |
| 窗口置顶(⌥⌘T) | 触控板双指横滑拖进度,纵向不被拦截 |
| 深浅色 / 减少透明度 / 减少动态效果 | 控制栏与详情页播放按钮跟随系统 |
| 主窗口浮动顶栏 | 玻璃按钮不压红绿灯、空白处可拖窗、滚动内容被渐变盖住、详情页 hero 透到顶、全屏下栏自动隐藏(Q37)、⌘F / ⌘[ |
| 首页 hero 轮播 | 8 秒换图、箭头与圆点在亮图上看得清、Logo 取不到退回文字、背景 404 露模糊海报、窄 / 宽窗口比例、悬停暂停、切 App 回来续上 |
| View →「Reload」(⌘R)/「Source」菜单(⌘1…⌘9) | 加载时栏下沿扫过细线 |
| 凭据文件迁移 | 首次启动弹「服务器数 + 1」次钥匙串授权(迁移),之后不再弹、不需重登 |
| 播放中不息屏 | `pmset -g assertions` 看 `PreventUserIdleDisplaySleep`;暂停后正常息屏 |
| **Q37** 控制栏 | 亮画面下衬底、640pt 窄窗口、自动隐藏节奏、长剧名截断、转码连点前后跳合并 |
| **Q40** 字幕外观 | ASS 强制套用,转码 seek 后保持,播放中即时生效 |
| 上一集 / 下一集 / 右侧选集抽屉 | 窄窗口、剧照尺寸、滚动定位、连点下一集队列 |
| 画面适配(填充 / 缩放 / 旋转 / 宽高比) | 2.39:1 选「填满」居中裁切;旋转 90° 后字幕跟着转而弹幕不转(宿主自绘) |
| 章节 | 进度条刻度、菜单跳转、⌘↑/⌘↓;转码流没有章节时入口与刻度都消失 |
| 音频延迟 C / V | 转码 seek 后保持 |
| 弹幕 | 暂停 / seek / 倍速同步、描边可读性、缩放后字号、全屏掉帧、菜单与面板排版、D 键 |
| 设置窗口 560×420 | 各标签页排版;改步长后方向键与按钮图标跟着变 |
| 百度目录落盘缓存 | 冷启动卡片立刻出、后台刷新后不整屏闪、断网能看已缓存目录、删 / 改名 / 隐藏后旧条目不再冒出 |
| 文件树来源 | 排序 / 筛选 /「已看 3 / 共 12 集」 |
| 百度同目录外挂字幕 | 自动挂上、按语言区分、不误配 |
| 本地外挂字幕 | GBK / BIG5 不乱码、无内嵌字幕时菜单可点、选错文件有提示 |
| 在线字幕(assrt) | 无密钥 / 配额超限 / 密钥无效的文案、`.idx` + `.sub` 提示换一条 |
| 每集记住字幕 | 关窗重播、转码拖动已实测;本地字幕被清后提示重选、在线字幕被清后自动重下、删服务器后清记录 |
| **Q56** 双字幕(`secondary-sid`,MPV_INTEGRATION.md 7.5) | 行高按 1.25 倍字号估算、字号 ×0.8;主字幕放大 / 上移后跟随、letterbox 片源(`sub-use-margins`)下位置、ASS 主字幕自带大字号时的重叠、转码 seek 后副字幕找回、字幕面板两段列表在窄窗口下的高度 |
| 本地文件夹来源整套界面 | 添加、浏览、详情、删除面板无「删除文件」、无重命名、文件夹挪走后重新选择、编辑页 |

## C. 缺外部条件的行为

### Q16 真实服务器上的播放

- DirectStream 能播(统计里显示「直接串流」)
- 转码能播,拖动进度可用
- 多音轨 / 多字幕切换正确,上报的 `AudioStreamIndex` / `SubtitleStreamIndex` 与 Emby 一致
- 关窗后 Emby Web 端进度正确
- 两台服务器之间切换不串台(进度、续播、图片)
- token 被吊销后回登录页 / 静默重登(⛔ 不去别人后台删设备制造 401)

`DirectPlayProfiles` 不限容器 / 编码,本地实例对 HEVC 10bit 也给 DirectStream,所以**转码路径在本地很难触发**
(需关直连或压低码率);`TranscodingProfiles`(HLS/TS/h264/aac)的服务端行为在 4.7 上未知:
- 触发转码后服务端按该 profile 给出 `TranscodingUrl`(m3u8),mpv 能播,seek 经 `StartTimeTicks` 重起流正常

### Q55 libmpv v0.42.0 基线的网络栈

v0.42.0 起网络流走 libcurl(HTTP/2、连接复用)、`tls-verify` 默认开、HLS 多变体 / MPEG-TS 多节目以 edition 暴露。
全部单测通过(含 DV 合成片源切 gpu-next);沙盒 test host 里 libcurl 对公网有效证书能开、自签名 / 过期被拒。
⛔ 本地实例是 http,覆盖不到 TLS 分支:HTTPS Emby 的 DirectStream 出画面与 `Range` 拖动、`http-header-fields` 认证头经 curl 带上、
转码 m3u8 不因 edition 分组漏轨 / 选错变体(不行再看 `--flatten-editions`)、115 / 百度网盘 CDN 直链经 curl 能播(依赖 UA / Cookie / Referer 头)、
换音频设备 / 改倍速回归(这两处 coreaudio 修复由上游 v0.42.0 提供,与本地补丁的版本不同)。

### 网盘分页

分页链路现在只有单测与第三方 SDK / 官方文档佐证。在一个**条目数 > 300 的真实目录**上,
115 `count` 是否等于目录总数、`offset` 不回绕且 `isOffsetHonored` 不在正常目录上误停、百度 `start` 连续翻 3 页累计条目单调增无重复无缺项、
百度 `list()` 全量路径 `limit=1000` 能取满(只在「剧 / 分集清单」触发,需 >1000 条的剧目录),都还是未知量。

不在上面的未知量里:翻页期间目录增删会不会漏项(官方只保证静态目录下的 `start + limit`,接受风险,靠顶栏「刷新」重列兜底,`BAIDU_PAN_API.md` §7.4);
`limit > 1000` 本项目⛔ 不越界,永不触发。

### 百度网盘来源(本机无开发者账号)

接口事实见 `docs/BAIDU_PAN_API.md`。下面这些需要一个已审核的开放平台应用才能核实:设备码授权轮询(`BaiduPanConnection.awaitAuthorization`)、
真实目录列表 + `filemetas` 批量换封面地址、`start` 偏移在目录条目多时可靠(浏览页一页 100 条,大目录要翻更多页,
偏移误差更容易暴露)、`dlink` 直连播放、`method=streaming` 转码出口的实际响应、`133`(要看广告)+ `adToken` 重试、
隐藏与「已隐藏」设置页恢复、删除 / 隐藏时连带清本地观看记录(`BaiduPanWatchHistory` 圈范围)、
本地已看 / 未看(剧卡只报「已看 N 集」,总数要列子目录,配额不允许;不跨机器同步;
正在播的集标已看后,下一次进度上报会把它带回「进行中」)、来源页「继续观看」、播放页换集队列(目录起播 0 额外请求;「继续观看」起播补列一次目录)、
选集抽屉封面(没配 TMDB token 时只能用同目录图或占位图)。
`limit>1000` 会被服务端怎么处理(报错 / 截断 / 忽略)查不到一手证据,⛔ 不越界。

**剧集详情页**(判定 `BaiduPanSeriesLayout`,界面 `FileSourceSeriesDetailView`):判定识别率在真实片库上未知。
季文件夹只认整个目录名就是季标记(`第13季` / `Season 2` / `S0`);`琅琊榜 第13季` 这类认不出,退回网格。
刻意的:放宽会把「电影」这类分类目录误判成剧。多季剧「共 N 集」改取 TMDB `number_of_episodes`(全剧),没命中时单季仍退本地数;
官方规格没写计算口径,是否含特别篇未知(`TMDB_API.md` §9)。进详情页为第一季多发一次列目录。
过渡(`FileSourceViewModel.navigatingDirectory` → `FileSourceDirectorySkeleton`)只有「缓存都没命中、真要发请求」时才立骨架,刷新当前位置不立;
逻辑由 `LocalFolderSourceTests` 的 `testEnteringADirectoryRaisesAndClearsTheNavigationPlaceholder` /
`testRefreshingTheCurrentDirectoryKeepsContentVisible` 覆盖;骨架与真实网格的高度是否一致、切进 hero 详情页时有没有一闪未知。
从「继续观看」或片库根直接进剧时没有目录卡片:剧级信息用续播快照兜底,`seriesProfile` 到了换成 TMDB 剧集海报,并补简介 / 年份。
「下一集」占位在一集变成已看时补(自然播完、越过 90% 关窗 / 换集、详情页或续播卡上标已看);同季没有就按季文件夹往后找
(每季末至多多列两次目录)。点过播放还没进度的集本身也是占位。网格里单条标已看不补;平铺存法、未分季不往外找。
季文件夹与平铺「未分季」并存的剧会出两张卡(键不同,⛔ 不为此列目录)。自然播完按 `end-file(.eof)` 落成已看(拖到结尾也算)。

### TMDB 在线刮削(本机无 token)

接口事实见 `docs/TMDB_API.md`。用自己的 v4 Read Access Token(设置 →「通用 → 元数据刮削」):
`/3/search/movie` / `/3/search/tv` 走通,Bearer 被接受;`/3/tv/{id}/season/{n}` 走通,`still_path` 的 `w300` 地址能拉到图;
`/3/tv/{id}` / `/3/movie/{id}` 按显式 `{tmdbid-N}` 直取走通;中文片名 + 年份能命中,`overview` 是中文(`language=zh-CN`);
`image.tmdb.org` 可达(本机曾 `Connection reset`,用户指示按可达处理;不通则只出文字、封面降级);429 阈值(官方约 40 次/秒,未实测);
详情页 `/3/{tv|movie}/{id}` 与 `/credits` 的实际取值与排版、`w185` 头像;多发的 1–2 次请求可接受。

已知限制:

- **平铺目录默认第 1 季**(`BaiduPanMetadataScraper.seasonWhenUnknown`),多季剧平铺会配错季。用季文件夹或 `SxxExx` 命名可避免。
- **电影目录不刮**(目录卡片只按剧查一次,除非目录名带 `{tmdbid-N}`);目录卡片只认标题完全一致。
- **显式 id 不区分影 / 剧**:剧集条目按剧查;目录卡片先剧后影;单条视频先影后剧(404 再换)。数字恰好两边都存在时会猜错,碰撞率未知。
  只有认得出集号的文件才借祖先目录的 id。
- **`status` 只映射 `Ended` / `Released`**(规格无枚举),其余原样显示英文。
- **详情页那一趟没有单独的失败提示**:刮削器失败原因是共用槽位,可能张冠李戴,所以整块隐藏。
- **`number_of_episodes` 的计算口径**:官方 OpenAPI 规格只给 `integer`,没说是否含第 0 季特别篇。
  它只作展示(详情页「共 N 集」),⛔ 不参与分集列表 / 换集队列;真实片库里与本地文件数的差值未知。

### 本地文件夹来源(单测用临时目录 + 书签替身)

- 书签跨启动:退出重开直接能列、能播(`files.bookmarks.app-scope` + 只读书签组合未实测)
- 外接盘拔插 / 换挂载点(`/Volumes/X 1`)后能恢复
- 网络卷未挂载时书签解析会不会自己去挂、卡住列表(没加 `withoutMounting`)
- libmpv 在同进程按路径读沙盒外文件、`sub-add` 本地字幕
- 大目录(上千文件 / 机械盘 / 网络卷)每次进都重读的体感;时长读文件头最多并发 4 个

已知边界:条目 id = 来源 id + 路径哈希(⛔ 不用 inode,exFAT 重挂会变),App 外改名会丢进度 / 已看 / 刮削缓存;
时长只认 mkv / webm / mp4 / m4v / mov;指向文件夹外的符号链接播放会被沙盒拒;本地封面也进海报磁盘缓存。

### 115 网盘来源(本机无 115 账号)

接口事实见 `docs/PAN115_API.md`。这条链路是**模拟网页客户端的非官方接口**(开放平台已于 2026-08-09 停服)。

- **扫码登录四步**(`Pan115Connection.startAuthorization` / `awaitAuthorization`):`qrcodeapi` 取 token → 状态轮询 `0/1/2` → `passportapi` 换 Cookie 四件套
- **`tv` 渠道的 Cookie 能不能调本项目这三个接口**:第 4 步绑定 `app=tv`(I1)后拿到的 Cookie,是否照样被
  `webapi/files`、`files/getid`、`proapi/app/chrome/downurl`(含 `f=3` 的 CDN Cookie)接受。AList 用 tv / 小程序 Cookie 挂载 115 Cloud 并走 302 下载是**强旁证**,
  p115client 也是一份 Cookie 打所有端点,但本项目没在真实账号上跑过。失败就退回 `web` 渠道并登记。
- **tv 与 Web 端是否真能长期共存**:2026-11-04 已实测「同渠道(`web`/A1)内重新扫码会互踢」,按 ssoent 换到 I1 是解法,
  但 §6 记了「设备数量上限 2 台」与社区反馈的跨端互踢,⛔ 不能保证 100% 不互踢。
- **`state: false` 的真实响应形态**:`Pan115Envelope` 已能解 Bool false 并映射成「请重新登录」,但这是按 §3 的 aps 实测形态写的;
  真实账号被顶下线时 `webapi/files` 到底回 `{"state":false,...}` 还是 `errno 990001` / `40101035` 未知。
- **列目录**(`Pan115Connection.files(in:)`):12 个参数被接受、`fid` 空串判目录、分页 1150 上限
- **`count` 是不是目录总条目数**:源码侧四路证据一致(`115-sdk-go` 的官方注释、`115driver` / `OpenList` / `p115client` 的终止条件、
  `get_file_count` 用 `page_size=1` 取总数)。本项目已按「`count` 是总数」实现(能精确判断还有没有下一页),若服务端实际给的是本页条数,
  翻页会提前停 —— 表现为「目录只显示一部分且不再加载更多」。若实际给的是本页条数,把 `Pan115APIClient.hasMore` 退回「不满页即到底」(与百度同口径),⛔ 不要两种判据都试。
- **`offset` 越界会不会静默回绕**:aps 接口的文档明写「相当于 offset=0,从头开始」,web 端 `files` 查不到确凿证据。
  本项目已加防护(服务端不认请求的 offset 就停),但防护是否会在正常目录上误停未知。
- **`files/getid` 路径换 cid**(`Pan115Connection.directoryID(path:)`):中文 / 空格路径的百分号编码服务端是否照收
- **「目录不存在」的错误码**:按 `p115client` 的注释认了 `800001` / `10014` / `20009`(片库根被删时静默回落网盘根),真实响应里到底回哪个码未知
- **`/app/chrome/downurl` 取直链**(`Pan115APIClient.downloadURL`):m115 加密的 `data` 被接受,解密后 `url.url` 是真 CDN 地址。加密层只与 p115cipher 的向量对过。
- **直链 `f` 参数三档**:空 / `1`(绑 UA)/ `3`(绑 UA + Cookie)。`f=3` 时用的 `Set-Cookie` 是不是取链响应里那个
- **播放**:mpv 带 `http-header-fields` 拉 115 CDN 直链能出画面;`Range` 拖动可用
- **直链过期后的 403**:重取一次能否恢复。现在只有「重取一次就报错」的实现
- **风控**:串行 500 ms 是否够(§6)是未知量,只能观察
- **Cookie 有效期**:未知,社区说法几天到几个月都有。现在**不主动探活** —— Cookie 失效会在第一次列目录
  (`webapi.115.com/files` 回 `errno 990001` / `40101035`)时暴露,那时浏览页直接切到扫码屏
- **网页版 m3u8 路线**(`GET https://115.com/api/video/m3u8/{pickcode}.m3u8`)完全没做。多音轨没声音的问题要靠它解决(直链只有默认音轨)。
  p115client 说它「只支持 web 的 cookies」且内层链接绑 UA
- **剧集详情页 / 续播卡 / 选集队列**:与百度共用同一套浏览页,但没有真实片库
- **删除**(`Pan115Connection.deleteFile` → `POST /rb/delete`,`docs/PAN115_API.md` §9):真实删一个文件、一个目录,
  看响应是不是 `state:1`、目录用 `cid` 当 `fid` 是否被接受、是否真的进回收站。⛔ 不要在常用账号上批量试 —— 删除不可并发,而且是写操作。
  `FileSource.supportsDeletingFiles` 已为 115 打开;若删除走不通就把它切回 false(浏览页只剩「隐藏」),⛔ 不要留一个点了会报错的开关。
- **改名**:115 没接(`FileSource.supportsRenamingSeries` 仍 false)

已知边界:

- **片库根存路径不存 cid**,`path → cid` 的索引只在内存里(`Pan115Connection.directoryIndex`,⛔ 不落盘 —— 映射错一位就会列到别人的目录)。
  进程重启后第一次进目录要重发一次 `files/getid`。
- **没有批量取直链**:`downurl` 虽收逗号分隔多个 `pickcode`,但响应 fileID 与请求顺序的对应关系未实测,⛔ 不猜。字幕是逐条取的,失败就跳过(不影响正片)。
- **不取封面**:`Pan115SourceProvider.content` 的 `durations` 恒为空、封面恒 nil,靠 TMDB 刮削补。省请求就是少风控面。
- **删除只删一条、不重试、删完不重新列目录**:115 的删除与还原互斥且不能并发(§9);`alreadyDeleted`(`231011`)按成功算。
  删完只做本地移除 + 目录缓存失效(`FileSourceViewModel.delete`),⛔ 不为刷新再发一次 `files`。
- **不支持从指定位置起流**:`Pan115SessionPreparer.makeSession(startTimeTicks:)` 带值即抛错(没有对位的起流参数)。续播靠客户端 seek。
- **`fs_id` 跨网盘不唯一**:`PlaybackSpeedStore.pan115Isolation` / 弹幕 / 手动标记都带 `pan115` 隔离段,⛔ 不要与百度的隔离段合并。

**命名债**:被百度与本地共用的纯函数仍叫 `BaiduPan…`(合成器 / 剧集布局 / 排序 / 字幕配对 / 路径工具 / 刮削器 / 两个本地库),
文件条目仍用 `BaiduPanFile`;`SourceProfile.emby` 仍复用 `ServerProfile`。改名是纯机械活,按需再做。

### Q29 打包了 libmpv 的 App 在没有 Homebrew 的 Mac 上是否正常

dylib 层已不依赖 Homebrew:固化产物含 libmpv 本体 + 49 个传递依赖,`@rpath` 互引、0 条 `/opt/homebrew` 加载路径;
本机用 `DYLD_PRINT_LIBRARIES` 加 `dlopen` 探针确认 0 次从 `/opt/homebrew` 加载(`Scripts/build-libmpv.sh` 的还原路径也只用系统工具)。
剩两处编译期数据文件路径,都没有第二台机器的数据:

- **OpenSSL CA**:`libcrypto.4.dylib` 内嵌 `OPENSSLDIR: /opt/homebrew/etc/openssl@4`,ffmpeg(`libavformat` / `libavcodec`)带 `--enable-openssl` 编、
  链了 `libssl.4` / `libcrypto.4`。mpv 网络流走系统 libcurl(`MPV_INTEGRATION.md §3.4`),平时碰不到这条路径;
  但只要有代码绕过 curl、让 ffmpeg 直接建 TLS 连接,没装 Homebrew 的机器上 CA 目录不存在 → HTTPS 证书校验失败。这是明确风险,不是「已解决」。
- **fontconfig**:产物里只有 `libbluray.4.dylib` 链 `libfontconfig.1.dylib`;`libass.9.dylib` 走 CoreText / ApplicationServices,不链 fontconfig。
  所以 **ASS 字幕不受影响**,受影响的只有 libbluray 的字体查找(蓝光菜单 / 文本字幕渲染)。

⛔ 现在不能声称「可在其他 Mac 上使用」。

### 弹幕(弹弹play;本机无应用凭据)

接口事实见 `docs/DANDANPLAY_API.md`,架构见 `docs/DANMAKU.md`。

- **Q45 Emby 合成文件名(`剧名 S01E03`)的 `/match` 命中率未知。** 模糊结果交给用户挑,同剧其它集按集号自动对上。
- **Q46 `comment` 端点 302 到加速服务后自定义头是否被带上 / 需要未知。** 签名已被真实服务接受(`/match` 回 200 + 业务错误码而非 403);403 时看 `X-Error-Message`。
- **Q47 作品剧集列表的 `episodeNumber` 只看过规格**(不一定是纯数字,多季合并时可能重复)。只认能解析成整数且唯一的一项,否则落回 `/match`。
- **Q48 `/match` 的 `fileHash` 必须是 32 位串**(结论来自第三方客户端)。没有指纹时填 32 个 `0`(`DandanplayMatchRequest.placeholderFileHash`)。
- **Q54 自建弹弹play 兼容服务的 `isMatched` 判定与官方是否一致未知。** 自建服务作为弹幕来源与官方并列(`DanmakuSource`,默认官方)。
  本地 danmu_api 与 Vercel 部署上 `match` / `bangumi` / `search/episodes` / `comment` 四个端点按 dandanplay 规范返回,签名头被忽略、
  鉴权看 URL 路径里的令牌(`docs/DANMU_API_FEASIBILITY.md` §2)。`isMatched` 的判定口径:实测 `火影忍者 S01E05` 命中《疾风传(2007)》第 5 话而非 2002 版,
  `遮天` 命中《手遮天(2026)》。LumaPlayer 对 `isMatched` 是直接采用并写集 / 剧绑定,错配会被缓存 4 小时。

## D. 工程与播放内核

- **网格骨架(`SkeletonGrid`)比真实 `ItemGridView` 矮。** 实测 12 项:骨架 884pt,真实(单行标题)1379pt、两行标题时更高 ——
  骨架卡片少一行副标题、`titleLine` 固定 `spacingM`(12pt),而真实卡片文字区钉 50pt。媒体库 / 搜索页骨架换内容时会把下方内容推走一截。
  修法同首页:让骨架复用真实卡片的文字区高度。
- **assrt 偶发返回 `sub.subs` 为字典而不是数组,解码失败。** 面板报「响应格式不对」而不是「没有搜到」。
  猜测是 PHP 把空数组编成 `{}`,⛔ 未证实,不要凭猜测改成「字典也当空」。
- **Q18 hardened runtime 生效时 `MPVPlayer()` 会让进程约 5 秒后死掉。** 无崩溃报告,原因未查明,所以 `ENABLE_HARDENED_RUNTIME = NO`。
  要分发时逐条加 `cs.allow-unsigned-executable-memory` / `cs.allow-jit` / … 实测定位,⛔ 不一次全加就宣布解决。
- **Q53 按码率标定的缓冲(`MPVCacheBudget`)。** 取值有单测,`demuxer-max-bytes` / `demuxer-max-back-bytes` 两条启动选项被真实 libmpv 接受(选项名写错会致命)。
  真实 Emby DirectStream 回退 30 秒内不再重新拉流、统计面板 `Cache` 实际读数、高码率片源不再频繁缓冲,都还没有数据。
- **Q32 中文简繁判定只在合成用例上跑过。** 只标 `chi` / `zho` 的轨排第三档;判不出不动。
- **M4 Emby `IsExternal` 字幕流(要带 token)怎么 `sub-add`。** 本地文件已支持;远程要沿用 `http-header-fields`,未实测。
- **Q42 杜比视界修复(自编 libmpv + gpu-next)。** 离屏 harness 复现 legacy 发绿、gpu-next 中性;按片源自动切换在合成 fixture 上能建起 gpu-next。
  真实 DV 片源(DirectStream / 转码)、`CAOpenGLLayer` 上屏、DV P7/P8 与 HDR10/HLG 回归、能耗(GPU 约为 legacy 的 4–5 倍)都没有数据。
  ⛔ 未修:PR 的 `map_frame` 上传失败时可能二次释放。上游合并后换基线、删补丁 0000,核对 `MPV_RENDER_PARAM_BACKEND` 编号。
  设置 →「播放 → 色彩」选「始终旧渲染器」是用户退回 legacy 的唯一入口。
  **P7 增强层(补丁 0006)**:只验了编译通过、现有 DV / 非 DV 合成 fixture 的后端测试不回归。合成不出带 EL 的片源,只能真实 P7 原盘 Remux 走 DirectStream 只读播放:
  FEL 片源 EL 是否真被合成(stats 看不出,要目检或对比 `vf=format:enhancement-layer=no`)、MEL 片源不上传 EL、EL 硬解走 VideoToolbox 零拷贝、
  多一路 1080p HEVC 解码的 CPU / GPU / 能耗,以及 BL 等 EL 配对带来的起播 / seek 延迟,都还没有数据。
- **Q49 render 队列 + `report_swap` + 按需 render 的副作用。** 弹幕帧率恢复(约 585 帧 / 5 s,主线程渲染时测的);
  `MPVRenderGateTests` 证明暂停期间不 render、改尺寸会重画、主线程堵住时照样出帧、正常播放时 VO 不因等 swap 丢帧。
  真实能耗、缩放 / 全屏 / 换屏(含 displayLink 跟屏)、窗口在别的桌面空间时的跳帧路径、60 fps 与 gpu-next、音画同步、
  主线程卡顿超 200 ms 时的丢帧程度(displayLink 在主 runloop 上)都没有数据。
  第一帧刚出就暂停、再恢复,VO 丢 2–3 帧(不报 swap 时 ≤1;displayLink 常开也一样,不是唤醒问题),推测是 VO 按 vsync 出帧后追不上刚起步的音频时钟;
  先播几十毫秒再暂停则为 0。真实片源上是否可见未知。
- **Q44「内核未就绪」门禁靠 `phase`,留着毫秒级竞态。** `FILE_LOADED` 与 UI 那一帧之间松手的拖动会被 mpv 拒(降级为 OSD)。
  流本身不可 seek(见 PITFALLS §2)时门禁也看不出来。
