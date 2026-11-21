# 资源发现:找资源 + 看什么

> 本文件是这两个模块的**唯一事实来源**,与 `BAIDU_PAN_API.md` / `PAN115_API.md` /
> `QUARK_API.md` / `TMDB_API.md` 平行。
> ⛔ 只用本文件列出的端点 / 参数 / 字段,不自行发明接口。

## 0. 两个问题,两条链路

| 问题 | 链路 | 落点 |
|---|---|---|
| **找资源**:网盘里没有的东西怎么找到并存进去 | 关键词 → 搜索源(TG 频道 / PanSou 实例)→ 归一化 → 去重排序 → 转存 | `Core/Discovery/`、`Features/Discovery/` |
| **看什么**:不知道要看什么 | 豆瓣 / TMDB 榜单 → 卡片 → 一键变成资源搜索关键词 | `Core/Discover/`、`Features/Discovery/DiscoveryView` |

两条链路在「看什么」的卡片上汇合:**点一张榜单卡片 = 拿它的标题去搜资源**。
这样「看什么」不只是一个榜单,它直接接到「找资源」上。

## 1. 为什么不做成 PanSou 的翻版

会话分析(session-26804fb3 / session-8f87eb4b)的结论是:PanSou 是**服务器端聚合器** ——
Go 写的,把关键词扇出到 100+ 个插件 + 111 个 TG 频道,靠两级缓存 + 短作业优先 + 后台补齐
把「一次问遍所有源」压进几秒。它自己**不存资源**,只聚合。

本项目的处境不同,所以照搬会做错:

| | PanSou | 本模块 |
|---|---|---|
| 部署 | 服务器,常驻 | 用户 Mac 上的 App,按需 |
| 源数量 | 100+ 插件 + 111 频道 | 个位数,用户自己挑的频道 |
| 网络 | 服务器直连,可配 SOCKS5 | 用户本机网络 |
| 缓存 | 两级(内存 + 分片磁盘)、TTL 策略、后台刷新 | **不做**(见 §2) |
| 调度 | 自适应并发 + SJF + 批截止 | 直接并发等齐 + 单源超时 |

**结论**:不把 PanSou 当「搜索后端」,而是在 App 里直接实现它那两条链路里**真正有效的那条**
—— Telegram 公开频道搜索(`t.me/s/{频道}?q=`)—— 源清单由用户自己维护(小而精)。

为什么放弃「接一个 PanSou 实例」:它一次问 100+ 个源,结果**杂**(同一部剧混进大量同频道的
无关条目),而且源的腐烂(站点关停 / 加反爬,会话里实测 `sousou` / `sdso` / `bixin` 那批已大面积失效)
全压在别人维护的实例上,用户既看不见也没法挑。

`panSou` 抓取方式**保留**为可选档:想接自己实例的人仍然可以加,但默认清单里没有它。

## 2. 没搬的三件事,以及理由

- **两级缓存**:PanSou 的缓存是为「同一个热门关键词被反复搜」设计的(公共 API)。
  本机是单用户,同一个词重复搜的概率低;而缓存会让「刚发的资源搜不到」变成一个难以解释的现象。
  ⇒ 每次真搜。要省流量就少配几个源。
- **SJF / 自适应并发**:源只有个位数,直接并发等齐更简单,也没有「4 秒后偷偷补数据」的状态。
- **后台补齐**:同上。超时的源记成失败(`PanResourceSourceFailure`),**如实显示**,
  而不是先给半份结果再悄悄补上 —— 用户看到的「没搜到」必须是真的没搜到。

保留的三条(PanSou 的核心价值):
1. **并发扇出 + 单源超时**(`PanResourceSearchService.sourceTimeout` = 15 秒);
2. **按分享地址去重,留信息更全的一条**(`merge`);
3. **失败归因**:哪个源挂了单独回传,⛔ 不把「某个源挂了」伪装成「没有资源」。

## 3. 看什么:榜单来源

### 3.0 为什么有两个来源

榜单来源会腐烂,而「看什么」不该因此整页打不开。所以数据源是**一个协议 + 两个实现**
(`DiscoverProvider`),`DiscoverTitle` 是与来源无关的页面模型。

| | 豆瓣 | TMDB |
|---|---|---|
| 凭据 | 不需要 | v4 Read Access Token |
| 地位 | **默认** | 配了 token 才有内容 |
| 协议 | ⚠️ 未公开,随时可能失效 | 官方 OpenAPI |
| 覆盖 | 中文语境的热门 / 国产剧 / 正在上映 | 全球热度,中文标题 |

豆瓣在前,是因为「没配 token 的人打开这一页」原本是一块空引导页 —— 那是本模块最大的可用性缺口。
TMDB 保留成第二档:**刮削仍然只走 TMDB**(季集信息、`{tmdbid-N}`、图片墙它才有),
榜单只是它的附加用途。

⚠️ 两条链路互不替代:榜单挂了不影响刮削,刮削没配 token 也不影响榜单出内容。

### 3.1 豆瓣:未公开接口

用的是豆瓣移动端网页自己打的 `rexxar` JSON 接口,**不是抓 HTML**(HTML 有反爬且结构常改):

```
GET https://m.douban.com/rexxar/api/v2/subject_collection/{collection}/items?start=&count=
```

实测出来的硬约束(2026-11):

| 约束 | 说明 |
|---|---|
| **必须带 `Referer`** | 指向 `https://m.douban.com/subject_collection/{collection}`;不带直接 **400** |
| `count` 上限 50 | 传 100 只回 50 条;本项目一页 20 |
| 翻页靠 `start` | `start=20` 返回第 21–40 条;越界(`start >= total`)返回空数组 + 200,不是错误 |
| `total` 是全量总数 | 用它判有没有下一页(`start + count < total`),⛔ 不用「本页装满没」推断 |
| 图床防盗链 | `img3.doubanio.com` 裸请求回 **418** + 14 字节占位,带任一豆瓣站点的 `Referer` 才给真图 |
| 无速率承诺 | 实测连打 10 次全 200,但不保证;所以单组 12 秒超时、失败如实显示 |

图床那一条**不改图片层**:`ImageDescriptor.remote` 本来就支持请求头
(`PosterImageLoader` 会塞进请求),建 descriptor 时带上 `DoubanImageHeaders.headers` 即可。

本项目收录的 collection(都实测过总量):

| collection | 标题 | 总量 |
|---|---|---|
| `tv_hot` | 热门剧集 | 209 |
| `movie_hot` | 热门电影 | 30 |
| `movie_showing` | 正在上映 | 86 |
| `tv_domestic` | 国产剧 | 50 |
| `tv_american` | 美剧 | 50 |
| `tv_animation` | 动画 | 20 |
| `movie_top250` | 豆瓣 Top 250 | 250 |

⚠️ **响应形状不统一**,除 `id` 外一律可选:
`movie_hot` / `movie_showing` 给 `cover` + `info` + `year`;
`movie_top250` 给 `pic` + `card_subtitle` 且**没有** `year`(年份从 `card_subtitle` 前 4 位取);
正在上映的片子整块 `rating` 是 `null`(⛔ 不补 0 分)。
`id` 是豆瓣 subject id,拼成 `"douban:{id}"` 当全局 id 与图片缓存 key 的版本段。

卡片上额外展示两个字段:

| 字段 | 出现范围 | 展示 |
|---|---|---|
| `card_subtitle` | 剧集 / Top 250 稳定给;电影不一定 | 卡片第三行,一行截断;悬停 `.help` 给全文 |
| `episodes_info` | 只有剧集给(`更新至12集` / `24集全`);电影没有 | 卡片第四行,**没有长度上限** |

⚠️ `episodes_info` 实测多数是六个字,但**不要假设它短** —— 个别条目会塞整段排播说明。
映射到 `DiscoverTitle` 时按 `episodesInfoMaxLength`(14 字)截断成 `episodesInfoLine`,
原值保留给 `.help`。⛔ 不做像素级截断:那会停在半个词上。

❌ 验过不可用的路:`api.douban.com/v2/*` 回 `apikey_is_blocked`;
`frodo.douban.com/api/v2/*` 回 997 签名校验。

### 3.1.1 当天缓存:同一个接口一天只请求一次

豆瓣的更新是**按天**的(剧集进度一天最多变一次),按小时 TTL 只会在一天里反复打同一个接口 ——
这正是要避免的。`DoubanDiscoverCache` 按**自然日**缓存原始响应字节,key 是完整请求 URL
(collection + `start` + `count`,所以翻页各页独立):

| 行为 | 规则 |
|---|---|
| 命中 | 同一个 URL + 同一天(`Calendar.isDate(_:inSameDayAs:)`) |
| 失效 | 换日即失效,没有滑动窗口;过期条目不删,留给排查 |
| 清理 | 写盘时丢掉 2 天以前的条目,超 200 条丢最旧的 |
| 存什么 | 原始响应字节(与 `EmbyResponseCache` 同立场),命中后走同一条解码路径 |
| 落盘 | `Application Support/LumaPlayer/douban-discover-cache.json`,0600、不进备份、原子写 |
| 失败 | 读 / 写盘失败只记日志,不挡请求(缓存是尽力而为) |

代价与取舍:当天新上架的条目要等第二天才出现,想立刻看到只能删掉那个 JSON。
**换来的是同一接口同一天最多一次请求**,反爬风控的风险压到最低。

### 3.1.2 翻页

两个来源的分页口径不同,`DiscoverProvider.load(_:page:)` 把它们折成同一个 `DiscoverPage`
(`items` + `hasMore`),上层只关心「还有没有下一页」:

| | 豆瓣 | TMDB |
|---|---|---|
| 偏移 | `start = page × 20` | `page` 参数(**1 起**,榜单层 0 起,入口 +1) |
| 边界 | `start + count < total` | `page < total_pages` |
| 越界 | 200 + 空数组 | 422(本项目不会翻到那里) |

⚠️ `hasMore` 一律**取来源自己给的边界**,⛔ 不用「本页是否装满」推断:豆瓣末页本来就不满。

界面落点:

- 首页货架:第一页 20 条;只有 `hasMore` 为真时标题旁才出现「查看全部」。
- 「查看全部」页(`DiscoverBoardView`):自适应海报网格,滚到离底一屏内自动翻下一页
  (`onScrollGeometryChange`),页脚另有显式「加载更多」按钮兜底;
  按 id 去重(分页期间榜单在变,同一条可能出现在相邻两页);翻页失败**不自动重试**,
  停在原地给一个「重试」按钮,否则会在触底处无限打接口。

⚠️ 页脚**不能**放进 `LazyVGrid` 的 cell 里,也不能只靠 `.task` 触发翻页:
cell 被回收 / 复用会让 `.task` 反复取消重启,而失败一次后那个 cell 不会再出现,
页面就永远停在「加载更多…」。现在页脚在网格外,触发走滚动位置 + 显式按钮两条路
(见 `docs/PITFALLS.md` Q65)。

### 3.2 TMDB:发现端点

参数对着官方 OpenAPI 规格(`https://developer.themoviedb.org/openapi/tmdb-api.json`)核实。

### 3.2.1 热门榜

`GET /3/trending/{media_type}/{time_window}?language=`

| 参数 | 位置 | 取值 | 说明 |
|---|---|---|---|
| `media_type` | path | `all` / `movie` / `tv` / `person` | 本项目用前三个 |
| `time_window` | path | `day` / `week` | 规格里只有这两个 |
| `language` | query | `zh-CN` | 同 `TMDB_API.md` §1 |

⚠️ `all` 里**混着人物**(`media_type: "person"`)。解码时按 `media_type` 分派,
人物的 `title` / `name` 语义不同,不是可播放内容 ⇒ 丢掉(`TMDBDiscoverResult.match`)。
⛔ 认不出的 `media_type` 一律当人物处理,不猜。

### 3.2.2 发现

`GET /3/discover/movie` / `GET /3/discover/tv`

本项目真正会传的参数(其余几十个不预先加进来):

| 参数 | 类型 | 说明 |
|---|---|---|
| `sort_by` | string | 只用三档,见 `TMDBDiscoverSort` |
| `page` | int | |
| `include_adult` | boolean | 显式传 `false` |
| `with_genres` | string | 逗号分隔的 genre id |
| `vote_average.gte` | number | 评分下限 |
| `vote_count.gte` | int | 评分人数下限 |
| `primary_release_date.gte` / `.lte` | string | `YYYY-MM-DD`,**只有电影侧** |
| `with_original_language` | string | ISO 639-1 |

**两条硬约束**:

1. `sort_by=vote_average.desc` **必须**配 `vote_count.gte`,否则会搜出「1 人打 10 分」的冷门片。
   代码在 `TMDBClient.discoverMovie/discoverTV` 里自动补 200(`defaultVoteCountFloor`)。
2. **剧集侧没有 `primary_release_date`** —— 它用的是 `first_air_date.*`。传了会被服务端**静默忽略**
   (不报错),所以 `discoverTV` 明确把日期区间清掉,⛔ 不留下「看起来传了其实没生效」的参数。

### 3.2.3 解码立场

`TMDBDiscoverResponse` 与 `TMDBSearchResponse` **分开**:搜索那边只解 `results`(不翻页),
发现要 `page` / `total_pages` / `total_results` 才能翻。形状不同就不硬塞进一个类型。

⚠️ `items.count` 与 `totalResults` 可能对不上(人物被丢掉),⛔ 不要拿它们互相校验。

## 4. 转存:哪家能做,哪家不能

| 网盘 | 能力 | 依据 |
|---|---|---|
| **115** | ✅ 能转存 | `webapi.115.com/share/snap`(列分享)+ `/share/receive`(收下) |
| **百度** | ❌ 用现在这套凭据做不到 | 见 §4.2 |
| **夸克** | ❌ 只读 | `QUARK_API.md` §9:TV 端 `MakeDir` / `Copy` / `Remove` 全部 `NotImplement` |
| UC / 其它 | ❌ 没接来源 | — |

### 4.1 115

端点与字段名逐字取自 `p115client` 的 `share_snap` / `share_receive`:

```
GET  https://webapi.115.com/share/snap?share_code=&receive_code=&cid=&limit=&offset=
POST https://webapi.115.com/share/receive   (表单)
     share_code= & receive_code= & file_id=<逗号分隔> & cid=<自己的目录 id>
```

要点:
- `/share/receive` 只认 **`file_id`**,不认路径 ⇒ 必须先 `share/snap` 拿到 id。
- `cid` 是**自己的**目标目录 id,115 **不建目录**。本项目因此要求目标目录已存在,
  ⛔ 不自动建目录(建目录是写操作,要用户明确同意)。
- `share/snap` 有 **IP 级频控**(文档原话:不登录也能看,但过于频繁会封 IP 一段时间)。
  所以走全 App 共用的 `Pan115RateLimiter`,并且只取一页(`Pan115SharePolicy.snapPageSize` = 32)。
- ⛔ **不重试**:转存是写操作,重发可能重复落盘,还多烧一次风控面。

⚠️ 本模块**未在真实 115 账号上实测**(手里没有可用的分享链接)。端点与字段名来自
`p115client` 源码(一手实现),响应形状按它的用法推断。见 `KNOWN_ISSUES.md` 的 Q60。

### 4.2 百度为什么不能转存

百度网盘的「分享文件转存」是 `POST /apaas/1.0/share/transfer`,但它属于**付费的企业开发者能力**:
按官方接入指南,要「购买文件分享服务并开通分享权限」,而且**文件分享服务属于企业开发者专属权益**
(需要企业开发者实名认证)。

本项目走的是**个人开发者**的 OAuth 应用(`scope=basic,netdisk`),拿不到这个接口的权限。

⇒ 这不是「还没做」,是「用现在这套凭据做不到」。所以 UI 里如实告知
(`PanResourceTransferService.baiduTransferUnsupportedReason`),⛔ 不给一个必然失败的重试按钮。
要支持百度转存只有一条路:改用企业开发者应用并购买该服务 —— 与本项目「自用、ad-hoc 签名」的定位冲突,
登记在 `KNOWN_ISSUES.md` 的 Q61。

## 5. 搜索源的可维护性

这是「资源来源最好做成可维护的」那条要求的落点。

### 5.1 数据,不是代码

源清单落 `Application Support/LumaPlayer/resource-sources.json`(0600、不进备份、
原子写,与凭据文件同目录)。设置 →「找资源」页可增删改停用。

为什么不做成 UserDefaults:这份清单是**用户要维护的数据**,要能导出 / 导入 / 手改;
JSON 文件比 UserDefaults 里的 blob 可维护得多。

### 5.2 抓取方式是一个封闭集合

```swift
enum ResourceSourceAdapterKind { case panSou, telegramChannel }
```

**加一个同类源 = 加一条 JSON;加一种新抓取方式 = 加一个 adapter case。**

为什么封闭:会话里验证过,PanSou 那 100+ 个站点里大量依赖站点私有加密(`sdso` 的 AES、
`yingso` 的 XOR + 配置接口)与登录态。把它们全做成配置项等于把「一个站改版就要改代码」
藏进 JSON —— 更糟,因为改的时候还得先读 JSON 才知道。

⇒ 只把**协议稳定**的几类配置化:

| kind | 端点 | 一个源 = |
|---|---|---|
| `telegramChannel` | `GET https://t.me/s/{频道}?q={关键词}[&before={id}]` | 一个频道 |
| `panSou` | `POST {base}/api/search` | 一个实例 |

`telegramChannel` 的 `baseURL` 存的是**频道名**(`tgsearchers7` / `@tgsearchers7` /
`https://t.me/tgsearchers7` 都认),不是站点根地址 —— 一个源一个频道,才能「只留几个」。

### 5.2.1 Telegram 频道的解析口径

`t.me/s/` 是给未登录用户看的公开预览页,不需要 token。实测(2026-11)结构:

| 要的东西 | 位置 |
|---|---|
| 消息边界 | `data-post="频道/消息id"`,每条一次、顺序即页面顺序 |
| 时间 | `<time datetime="RFC3339">` |
| 正文 | `<div class="tgme_widget_message_text …">…</div>` |
| 翻页 | `<a data-before="{最小消息id}">` |
| 网盘链接 | 正文里的 `<a href>`(Telegram 会把 URL 包成锚点) |

- 切块按 `data-post` 而不是嵌套 `<div>`:正文里嵌着 `<a>` / `<i>` / `<mark>`,按标签配对容易错位。
- 标题取正文里 `名称:` 那一行;摘要取 `描述:`;没有就退回首行 / 前 400 字。
- 提取码优先取 URL 的 `?pwd=` / `?password=`,其次正文的「提取码:xxxx」。
- **没有网盘链接的消息不是资源**(纯文字更新),丢弃。
- ⛔ 不收 `t.me` 自己的链接(频道互推 / 标签搜索页)。
- 频道不存在时 `t.me/s/…` 会 302 到 `t.me/<频道>`(联系页),跟随后**没有消息块**。
  所以「0 条结果」与「频道名错了」分开报 —— 后者是 `sourceFailed`,不是空结果。

⚠️ 只翻 **2 页**(`maxPages`,一页 20 条)。频道里同一条资源常被反复重发,翻更多页收益很低。

### 5.3 默认清单:几个实测能用的频道

`ResourceSourceStore.builtInSources` 预置 6 个 Telegram 频道(综合 / 夸克 / 阿里 4K / UC / 国漫 / 短剧),
选材口径是「`?q=` 实测能返回 20 条、正文是 `名称/描述/网盘链接` 格式」。

⛔ **不预置 PanSou 实例**:那一档会把关键词扇到上百个源,杂且依赖别人维护。
频道也会关停,所以这只是**起点**——设置页能加 / 改 / 停用 / 删。

### 5.4 降噪

`PanResourceSearchService.filterRelevant`:标题 + 摘要里命中关键词(按空白切词)的才保留。

口径刻意放宽:单个词 < 2 字符不参与判断;**一条都不剩时退回原结果** ——
宁可杂一点,也不能因为启发式让用户看到「没搜到」。

## 6. 请求纪律

- 单个源 15 秒超时,超时**取消**任务(⛔ 不留还在跑的请求)。
- 豆瓣单组 12 秒超时(未公开接口,卡住时早点把失败交给用户)。
- 翻页**串行**:`isLoadingMore` 挡住连点,同一页不会被请求两次、结果不会互相覆盖。
- 翻页失败停在原地等用户点「重试」,⛔ 不在触底处自动重试(会变成对未公开接口的连续打点)。
- 上一次搜索还在跑就取消(连按两次回车不该让两个结果互相覆盖)。
- 榜单**全部并发**(跨来源也是),各自独立失败;已有内容时不退回 loading(不闪屏)。
  一个来源挂了只影响它自己的几组,⛔ 不把整页拖红。
- 不可用的来源(没配 token)整组**不发请求**,也不进状态表,单独记进 `unavailable` 给引导页。
- 图片走 `ImageDescriptor.remote` → `PosterImage`(⛔ 不裸用 `AsyncImage`),
  缓存分区用固定 id(`DiscoverTitle.imageOwner`),不跟随任何来源。

## 7. 未实测清单

| 项 | 状态 |
|---|---|
| 115 `share/snap` 真实响应字段(`is_dir` / `fid` / `s` 是否如 `p115client` 所述) | ❌ 无凭据实测 |
| 115 `/share/receive` 的成功响应形状与错误码 | ❌ 无凭据实测 |
| 115 转存是否需要先「接收过」才允许重复接收 | ❌ 未知 |
| PanSou 公共实例的可用性 | ⚠️ 随时间变化,所以默认不预置 |
| Telegram 频道清单的长期可用性 | ⚠️ 频道会关停 / 改格式;失效时该源单独报错,不会静默空 |
| `t.me/s/` 页面结构 | ⚠️ 2026-11 实测;改版时解析会退化成「0 条」,需跟着改正则 |
| TMDB `trending` 的 `person` 占比 | ⚠️ 未统计;解码已按 `media_type` 过滤 |
| 百度的 `share/transfer` 是否对个人开发者完全不可用 | ⚠️ 依据官方接入指南的「企业开发者专属」表述,未尝试申请 |
| 豆瓣 `rexxar` 接口的长期可用性 | ⚠️ 未公开接口,2026-11 实测可用;失效时该组会红,不会静默空 |
| 豆瓣翻页的总页数与 `total` 是否始终一致 | ⚠️ 抽查 `tv_hot` 的 `start=20` / `200` / `400` 都对;跨页期间榜单变化会让同一条重复出现,已按 id 去重 |
| 豆瓣的速率上限 | ⚠️ 实测连打 10 次全 200,没有已知的 429 阈值 |
