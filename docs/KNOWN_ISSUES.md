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
- **Q39 播放上报 `SubtitleOffset` 单位未知,字幕延迟不上报。** 官方只写「floating point value」。字幕延迟只在客户端生效(mpv `sub-delay`)。
  结案:本地实例上用 Emby Web 调一次字幕偏移,看 `Progress` 请求体里的值与界面「秒」的关系,回填 API_CONTRACT.md 5.1。

## B. 已实现、未视觉 / 实机确认

本机能截图但没有辅助功能权限,需要交互的画面要人来操作。确认一项删一项。

| 项 | 怎么确认 |
|---|---|
| Q6 `hwdec-current` 实际解码器 | 播放时看统计面板「解码」 |
| 下一集提示:无片头标记时结束前 10 秒出现,倒计时结束自动换集,取消后不再出现 | 播一集拖到片尾 |
| 起播自动选中简体(其次繁体)中文字幕;只有英文轨时不动 | 播带中文字幕轨的片子,看「字幕」菜单勾选 |
| 缓冲百分比 / 网速 / 进度条已缓存段 | 播远程大文件 |
| 控制中心「正在播放」的封面、上一曲、倍速 | 播放时开控制中心 |
| 窗口置顶(⌥⌘T);触控板双指横滑拖进度,纵向不被拦截 | 播放窗口里试 |
| 深浅色、「减少透明度」「减少动态效果」下的控制栏与详情页播放按钮 | 系统设置切换后看 |
| 详情页头部(非全屏):无工具栏背景色、无服务器切换,hero 图透到标题栏下 | 打开任一详情页 |
| 凭据从钥匙串迁到文件:首次启动弹「服务器数 + 1」次授权窗,之后不需重登、后台不多设备,再部署不再弹窗 | 装新版后首次启动 |
| 播放中不息屏:显示器休眠设 1 分钟连播 5 分钟不息屏,暂停后正常息屏 | `pmset -g assertions` 看 `PreventUserIdleDisplaySleep` |
| **Q37** 控制栏改版:亮画面下压暗衬底够不够、播放头尺寸、640pt 窄窗口挤不挤、自动隐藏 2s / 0.3s 是否顺眼、长剧名截断、「21:35 结束」宽度、转码下连点前后跳的 0.25s 合并是否无感 | 有可播媒体时亮 / 暗场各截一次 |
| **Q40** 字幕外观:字号 / 颜色 / 粗体 / 描边 / 阴影 / 底框实际效果,ASS 强制套用后排版,转码 seek 后外观保持,播放中改即时生效 | 播同时有 SRT 与 ASS 的文件 |
| 设置窗口 560×420 下四个标签页排版;改步长后方向键与前后跳按钮图标跟着变 | ⌘, 打开截图 |

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

### 百度网盘来源(本机无开发者账号,全部只有 mock 覆盖)

接口事实见 `docs/BAIDU_PAN_API.md`,落地见 `docs/SOURCE_ABSTRACTION_PLAN.md`。结案要一个已审核的开放平台应用:

- [ ] 设备码授权轮询(`BaiduPanConnection.awaitAuthorization`)真实走通
- [ ] 真实目录列表 + `filemetas` 批量换封面地址
- [ ] `dlink` 直连播放、`method=streaming` 转码出口的实际响应
- [ ] `133`(要看广告)+ `adToken` 重试
- [ ] 来源页「继续观看」区:播一半退出再进,卡片出现、封面出得来(磁盘缓存命中或 `dlink` 未过期)

### TMDB 在线刮削(已接入百度来源;本机无 token,全部只有 mock 覆盖)

接口事实见 `docs/TMDB_API.md`。**已接入** `BaiduPanSourceProvider`:列目录后的第二趟由
`BaiduPanMetadataScraper` 跑刮削(没填 token 时一个请求都不发;失败只挂提示横幅,不影响浏览)。
下面这些只有真实网络才能结案 —— 用一个用户自己的 TMDB 账号
(在设置 →「通用 → 元数据刮削」填入 v4 Read Access Token):

- [ ] 真实 `GET /3/search/movie` / `/3/search/tv` 走通,Bearer 认证被接受(不是 401)
- [ ] 真实 `GET /3/tv/{id}/season/{n}` 走通(2026-10-12 新增:刮削钻到分集拿剧照 / 集名 / 单集简介);
      分集剧照 `still_path` 拼出的 `w300` 地址能拉到图
- [ ] 中文片名 + 年份能命中,`overview` 回来是中文(`language=zh-CN`)
- [ ] `poster_path` 拼出的 `image.tmdb.org` 地址真的能拉到图(⛔ 本机实测该主机三次 `Connection reset`,
      用户指示按可达处理;若真机上不通,刮削只能出文字信息、封面降级)
- [ ] 429 频率限制在真实 token 下的阈值(官方约 40 次/秒,未实测)

**已知限制(2026-10-12,钻到分集这一版引入):**

- **平铺目录默认按第 1 季。** `琅琊榜/01.mp4` 这种文件名没写季号、又没有季文件夹的存法,
  刮削层拿**第 1 季**去问 TMDB(`BaiduPanMetadataScraper.seasonWhenUnknown`)—— 多季剧平铺时会配错季的剧照。
  缓解:改用季文件夹(`琅琊榜/第13季/`)或文件名带 `SxxExx` 命名,季号就能认出来。⛔ 待真实片库验证识别率。
- **电影目录不刮。** 目录卡片只按**剧**查一次(⛔ 不为一个目录查两次,免得 50 个目录的片库多烧一倍请求);
  片名做目录名的电影库拿不到封面。
- **目录卡片只认标题完全一致。** 归一化后不完全一致就**不给封面**(比单条文件的「唯一结果就认」更严,避免配错剧)。

### Q29 打包了 libmpv 的 App 在没有 Homebrew 的 Mac 上是否正常

本机确认 0 次从 `/opt/homebrew` 加载 dylib,但没有第二台机器。fontconfig / OpenSSL 运行时仍按编译期路径读数据文件。
⛔ 做完之前不得声称「可在其他 Mac 上使用」。结案:另一台无 Homebrew 的 Mac 装 DMG,确认启动、直接串流、转码、ASS 字幕、HTTPS。

## D. 工程与播放内核

- **Q18 hardened runtime 生效时 `MPVPlayer()` 会让进程约 5 秒后死掉。** 无崩溃报告,原因未查明,所以 `ENABLE_HARDENED_RUNTIME = NO`。
  只在换回证书签名时才会冒出来。要分发时逐条加 `cs.allow-unsigned-executable-memory` / `cs.allow-jit` / … 实测定位,⛔ 不一次全加就宣布解决。
- **M2 `demuxer-max-bytes` 未按真实码率标定。** 现为 128 MiB,4K remux(~80 Mbps)下约 13 秒。高码率远程流仍频繁缓冲再按 `MediaSource.Bitrate` 动态算。
- **Q32 中文简繁判定只在合成用例上跑过。** 关键词表(`zh-Hans` / `chs` /「简体」/ `Simplified` …)没见过真实资源。
  只标 `chi` / `zho` 的轨排第三档;判不出不动。结案:找一部同时有简繁轨的片子,记下 `lang` / `title` 原文回填单测。
- **M4 外挂字幕加载需要认证的远程 URL 是否可行(`sub-add` 怎么带头)。** 目前只用容器内轨,未实现。
- **Q42 杜比视界修复(自编 libmpv + gpu-next)未在真实片源 / 上屏画面验证。**
  已验证:离屏 harness 复现 legacy 发绿、gpu-next 中性;回退出非黑帧;单测覆盖默认 / 关偏好两条路径。
  ⛔ 未验证:真实服务器 DV 片源、`CAOpenGLLayer` 上屏画面、DV P7/P8 与 HDR10/HLG 回归、真实 4K 片源能耗(GPU 仍约为 legacy 的 4–5 倍)。
  ⛔ 未修:PR 的 `map_frame` 上传失败时可能二次释放(查 `pl_queue` 对 map 失败帧是否还回调)。
  上游合并后:改回官方仓库与 sha,核对 `MPV_RENDER_PARAM_BACKEND` 编号,能删的补丁删掉。
  在此之前,设置 →「播放 → 色彩」选「始终旧渲染器」是用户唯一能自己退回 legacy 的入口。
  按片源自动切换只在合成 fixture(只有 `dvcC`、无 RPU)上验过 VO 按 gpu-next 建起;⛔ 未验:真实 DV 片源经 DirectStream /
  转码时 mpv 能否读到配置记录(转码输出大概率不带 DV,会留在 legacy)、自动模式下 SDR 片源的实际能耗下降。
