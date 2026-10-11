# Emby API 契约

> Emby 接口的唯一事实来源。代码不得自行发明端点、参数或字段名(`CLAUDE.md` 硬规则 1)。
> **章节编号稳定**,代码注释按编号引用(如「API_CONTRACT.md 4.4」),改文档时不要重排。

## 0. 怎么用

### 0.1 标记

| 标记 | 含义 | 能否直接实现 |
|---|---|---|
| ✅ | 已对官方文档 / OpenAPI / 真实请求核实 | 能 |
| 🔶 | 高置信(社区惯例、仅本地实例实测),未在真实服务器核实 | 能,但在 `KNOWN_ISSUES.md` 挂一条 |
| ⚠️ | 未核实 | **不能**,先核实回填 |

文档里没有的端点 / 参数 / 字段一律按 ⚠️。

### 0.2 核实方法(按可靠程度)

1. **看 Emby Web 自己怎么发请求**(浏览器抓包,或本地实例 `/web/` 下的前端源码);
2. 官方 OpenAPI:`https://swagger.emby.media/openapi.json`(4.1.1.0,直接下载查 `paths` / `components.schemas`;
   Swagger 页面是 JS 渲染抓不到,Emby 4.9 内置的 `/emby/swagger-ui/*` 全 404);
3. 真实请求:本地实例 `Tools/emby-dev/`(4.9.5.0)随便试;别人的服务器只读、低频、单次。

⚠️ 规格(4.1.1.0)、本地实例(4.9.5.0)、实测过的真实服务器(4.7.11.0)三者版本都不同。

### 0.3 回填

核实后在同一次提交里改标记、写来源与日期;与文档不符**以实际为准改文档**;
能存 fixture 的存脱敏 fixture;`KNOWN_ISSUES.md` 对应条目移除。

## 1. Base URL

### 1.1 前缀 ✅

官方形式 `http[s]://host:port/emby/{apipath}`。注意 **`/emby` 前缀**。

### 1.2 存储约定

`ServerProfile.baseURL` 存**不含 `/emby` 的站点根**(`https://example.com/media/emby` → `https://example.com/media`);
前缀单独存在 `ServerProfile.apiPathPrefix`(`/emby` 或 `""`),探测时确定,⛔ 不要每次请求时猜。

### 1.3 URL 规范化(`normalizeServerURL`,有单测)

返回 `NormalizedServerURL { url, schemeWasInferred }`。步骤:去首尾空白 → 无 `://` 补 `https://`
并记 `schemeWasInferred = true` → `URLComponents` 解析 → scheme 只许 http/https →
host **非 nil 且非空**(`URLComponents(string: "https://")` 的 host 是 `""` 不是 nil)→ host 小写 →
去默认端口 → 去末尾 `/` → 去末尾 `/emby`(大小写不敏感)→ 丢 query / fragment。

### 1.4 前缀探测与 scheme 回退

依次试 `{baseURL}/emby/System/Info/Public`、`{baseURL}/System/Info/Public`,第一个 200 + JSON 的定前缀。
都失败时,**仅当**「用户没写 scheme」且 `isLocalOrPrivateHost(host)`(localhost、`.local`、
127/8、10/8、172.16/12、192.168/16、169.254/16、`::1`、fc00::/7、fe80::/10)才换 http 再试一轮。

- 回退成功:`baseURL` 存回退后的 `http://…`,UI 标「未加密连接」,`ServerCompatibility` 记一笔;
- ⛔ 用户明确写了 https 不降级;⛔ 公网 host 不回退;⛔ 不先试 http。

## 2. 认证

### 2.1 Authorization 头 ✅

```text
Authorization: Emby UserId="{userId}", Client="LumaPlayer", Device="{device}", DeviceId="{deviceId}", Version="{version}"
```

- scheme `Emby` + 空格;键值对之间 `, `;值用双引号;键名大小写敏感;
- **未登录时省略整段 `UserId="..."`**,不写 `UserId=""`;
- `Device` = `Host.current().localizedName`,去掉 `"` 与 `\`,含非 ASCII 则回退为 `Mac`;
- `Version` = `CFBundleShortVersionString`,不硬编码。

### 2.2 Token ✅

独立的 `X-Emby-Token: {accessToken}` 头,不放进 `Authorization`。

### 2.3 不用的方式

⛔ `X-Emby-Authorization: MediaBrowser ...`(Jellyfin 风格);⛔ `api_key` 查询参数(仅 6.2 的退路)。

### 2.4 DeviceId

首次启动 `UUID().uuidString`,存凭据文件(account `deviceId`);旧版在钥匙串,升级时原样导入,⛔ 不重新生成。
**全 App 一个**,删服务器时不删 —— 按服务器生成会让 Emby 后台出现重复设备。

### 2.5 401 ✅

Emby token 不过期,401 = 服务端吊销(后台删设备、改密码、同 DeviceId 同用户再登录顶掉、重装)。

| 场景 | 行为 |
|---|---|
| 手上 token 在请求期间已被别处换新 | 用新 token 重发一次 |
| 记住了密码 | 静默 `AuthenticateByName` 一次,成功后原请求重发一次;仍 401 → 清 token 与密码,回登录页 |
| 静默登录本身 401 | 清 token 与密码,回登录页 |
| 静默登录遇网络等其他错误 | 原样抛出(不伪装成 401),密码保留 |
| 没记住密码 | 清**这台**、**那次请求用的** token,回登录页 |

⛔ 不影响其他服务器;⛔ 不循环重试;并发的多个 401 共用同一次静默登录。

## 3. 端点

路径都加 `{baseURL}{apiPathPrefix}` 前缀。

### 3.1 探测与认证

| 方法 | 路径 | 用途 | 状态 |
|---|---|---|---|
| GET | `/System/Info/Public` | 免认证探测:服务器 Id、名称、版本 | ✅ 4.7.11.0 实测免认证 200 |
| GET | `/System/Info` | 需认证 | ✅ |
| GET | `/Users/Public` | 公开用户列表 | ✅ |
| POST | `/Users/AuthenticateByName` | 登录,body `{"Username": "...", "Pw": "..."}` | ✅ 4.7.11.0 实测 |
| POST | `/Sessions/Logout` | 登出 | ✅ |

- 登录响应 ✅:`AccessToken`、`User.Id`、`ServerId`。
- ⛔ 不做「失败后改小写 `pw` 重试」:会把真正的密码错误伪装成字段名问题。
- 密码明文在 body:非 HTTPS 时 UI 警告;不进日志 / fixture。

### 3.2 浏览

| 方法 | 路径 | 用途 | 备注 |
|---|---|---|---|
| GET | `/Users/{UserId}/Views` | 媒体库入口 | ✅ `CollectionType` 可为 null(混合库) |
| GET | `/Users/{UserId}/Items` | 通用查询 | ✅ 参数见下 |
| GET | `/Users/{UserId}/Items/{Id}` | 单项详情 | ✅ 默认就带 `People` / `Studios` / `Taglines` / `MediaStreams` |
| GET | `/Users/{UserId}/Items/Resume` | 继续观看 | ✅ ⚠️ **必须带 `Recursive=true&MediaTypes=Video`**(照抄 Emby Web),否则 4.9.5.0 恒 0 条 |
| GET | `/Users/{UserId}/Items/Latest` | 最近添加 | ✅ ⚠️ **裸数组**,无 `StartIndex` / `SortBy` |
| GET | `/Shows/NextUp` | 下一集 | ✅ ⚠️ 路径里**没有** `{Id}`,`SeriesId` / `UserId` 是查询参数;现在只用带 `SeriesId` 的形式(Q31) |
| GET | `/Shows/{SeriesId}/Seasons` | 季 | ✅ |
| GET | `/Shows/{SeriesId}/Episodes` | 分集 | ✅ |
| GET | `/Items/{Id}/Similar` | 更多类似 | ✅ |

响应:`Latest` 是 `BaseItemDto[]`;`Items/{Id}` 是单个 `BaseItemDto`;其余都是
`{"Items": [...], "TotalRecordCount": n}`。⛔ 不要按其他列表端点类推 `Latest`(Q23)。

**`/Users/{UserId}/Items` 参数** ✅:`ParentId`、`Recursive`、`IncludeItemTypes`、`MediaTypes`、
`SortBy`(`SortName` `DateCreated` `DatePlayed` `PremiereDate` `ProductionYear` `CommunityRating` `CriticRating` `PlayCount` `Runtime` `Random`)、
`SortOrder`(`Ascending` / `Descending`)、`Fields`(`Overview` `Genres` `People` `Studios` `Taglines` `MediaStreams` `DateCreated` `ProviderIds` `PrimaryImageAspectRatio`)、
`Limit`、`StartIndex`、`Filters`(`IsPlayed` `IsUnplayed` `IsFavorite` `IsResumable` `IsFolder` `IsNotFolder` `Likes` `Dislikes`)、
`SearchTerm` 🔶(官方只列在 `/Search/Hints` 上;本地 4.9.5.0 可用,Q12)。

- ⚠️ 带 `SearchTerm` 时 `TotalRecordCount` 恒为 0,不能用来判断分页(Q24)。
- ⚠️ `Filters=IsResumable` **只在带 `ParentId` 时可信**:4.7.11.0 上不带 `ParentId` 返回的是媒体库条目(Q28)。
- ⚠️ `IncludeItemTypes` 用在 `Resume` 上只能填可播放叶子类型,掺进 Series / Season / BoxSet 就归零。
- 列表接口字段比单项少,要 `Overview` 等必须显式 `Fields=`。

### 3.3 图片 ✅

`/Items/{Id}/Images/{Type}[/{Index}]`(`Primary` `Art` `Backdrop` `Banner` `Logo` `Thumb` `Disc` `Box` `Screenshot` `Menu` `Chapter`);
参数 `MaxWidth` `MaxHeight` `Tag` `Format` 等。

- 对象上对应的 tag 有值才请求,否则 404;**tag 存在 ≠ 图一定取得到**(Q35),装饰性图片要留退路;
- 必须传 `MaxWidth` / `MaxHeight`(海报 `MaxWidth = 300`);
- 缓存 key 不含 host(内外网切换复用),但**必须含 `Tag`**;没有 `Tag` 的图不进磁盘缓存;
- 父级继承:`ParentBackdropItemId` + `ParentBackdropImageTags`、`ParentLogoItemId` + `ParentLogoImageTag` 等;
- 是否需要认证头未核实(Q12)→ 一律带完整认证头,所以图片只能经 `PosterImage` 请求。

### 3.4 BaseItemDto 字段 ✅

只有 `Id` / `Name` 必填(8.1),其余可选。用到的:`Type`、`Overview`、`ProductionYear`、`RunTimeTicks`(仅展示,播放时长见 4.3)、
`IndexNumber` / `ParentIndexNumber`、`SeasonId` / `SeriesId` / `SeriesName` / `SeasonName`、`Genres`、`OfficialRating`、
`CommunityRating`、`CriticRating`、`PremiereDate`、`ChildCount`、`Taglines`、`ImageTags`、`PrimaryImageTag`、
`BackdropImageTags`、`Parent*ItemId` / `Parent*ImageTag(s)`、`People`(`Id` `Name` `Role` `Type` `PrimaryImageTag`)、
`Studios`(⚠️ 只解 `Name`:4.1.1.0 里 `Id` 是 int64,跨版本未核实)、`MediaStreams`(另解 `DisplayTitle` `Width` `Height` `Channels` `Title`)、
`UserData`(`PlaybackPositionTicks` `Played` `PlayedPercentage` `PlayCount` `IsFavorite` `LastPlayedDate` `UnplayedItemCount`)。

⚠️ 4.1.1.0 的 `BaseItemDto` 没有 `PrimaryImageTag`:两个都解,`ImageTags["Primary"]` 优先,都没有就不发请求(Q13)。

## 4. 播放

### 4.1 Emby 的三个术语 ✅

Direct Play = 客户端**直接读文件系统**的 `Path`,绕过服务器;Direct Stream = 从服务器原样串流;Transcode = 服务端转码。

### 4.2 LumaPlayer 只有两条路径

LumaPlayer 是纯 HTTP 客户端,不挂载网络存储,所以没有 Direct Play:

| 路径 | URL | 上报 `PlayMethod` |
|---|---|---|
| DirectStream | 4.5 / 4.5.1 | `DirectStream` |
| Transcode | `TranscodingUrl` | `Transcode` |

`PlaybackPlan` 只有 `.directStream` / `.transcode`。⛔ 不加 `case direct(url:)` / `case directPlay(...)`。

### 4.3 PlaybackInfo

`POST /Items/{Id}/PlaybackInfo` ✅。请求体(schema `MediaInfo.PlaybackInfoRequest` ✅)当前只发:

```json
{ "UserId": "...", "EnableDirectPlay": false, "EnableDirectStream": true, "EnableTranscoding": true }
```

(转码 seek 重新起流时另带 `StartTimeTicks`。)schema 里还有 `MaxStreamingBitrate` / `AudioStreamIndex` /
`SubtitleStreamIndex` / `MediaSourceId` / `DeviceProfile` 等,存在但不发。

- `EnableDirectPlay` 固定 **`false`**:传 true 会拿到一个打不开的服务端本地 `Path`。
- `DeviceProfile` ⚠️:完全省略。后果是 4.9.5.0 对 HEVC 10bit 也只给 DirectStream,转码路径很难触发(Q16)。
  要补只补必要的 `DirectPlayProfiles`;⛔ 不凭想象写几百行 profile。

响应 ✅:`MediaSources`(可空 / 缺失)、`PlaySessionId`(schema 不 required → 可选)、`ErrorCode`
(`NotAllowed` / `NoCompatibleStream` / `RateLimitExceeded`,按普通字符串解)。

`MediaSource` 字段 ✅:`Id`、`Container`、`Bitrate`、`Size`、**`RunTimeTicks`(时长以此为准,不用外层 Item 的)**、
`MediaStreams`、`Name`、`DefaultAudioStreamIndex`、`DefaultSubtitleStreamIndex`、`SupportsDirectStream`、
`SupportsTranscoding`、`DirectStreamUrl`(4.5.1)、`TranscodingUrl`(相对路径)、`TranscodingSubProtocol`。
`Path` 不用;`LocationType` / `VideoType` 官方 schema 没有,不解(Q15);`RequiredHttpHeaders` 存在但不用。

### 4.3.1 章节与片头片尾(`MediaSource.Chapters`)

`StartPositionTicks` ✅、`Name` ✅、`MarkerType` ✅ 字段 / 🔶 取值(`Chapter` / `IntroStart` / `IntroEnd` / `CreditsStart`,按自由字符串解)。
取**源上的** `Chapters`。片头 = `IntroStart`→`IntroEnd`(都在且终点晚于起点);片尾起点 = `CreditsStart`。
**没有标记是常态**:没有就不显示「跳过片头」,下一集提示退回「结束前 10 秒」(Q30)。

### 4.4 决策算法(全 fixture 覆盖)

```text
1. ErrorCode != nil              → 抛 serverRejected(code)
2. MediaSources 为空              → 抛 noMediaSource
3. 选源:只有 1 个用它;多个取第一个 SupportsDirectStream 的,都不支持取第一个
4. source.SupportsDirectStream   → .directStream
5. source.TranscodingUrl 非空     → .transcode(baseURL + TranscodingUrl)
6. 都不满足                        → 抛 noPlayablePath
```

⛔ 第 6 步不得自己拼一个猜的 URL 去试。`PlaySessionId` 缺失时抛 `missingRequiredField`,不变成空串。

### 4.5 串流 URL ✅

```text
{base}{prefix}/Videos/{itemId}/stream.{container}?static=true&MediaSourceId={sourceId}&PlaySessionId={playSessionId}
```

扩展名取**输出**格式(DirectStream 即 `MediaSource.Container`)。这是 4.5.1 解析不了时的退路。

**Seek** ✅:DirectStream 客户端自由 seek,交给内核;**Transcode 不能客户端 seek**,必须停流 +
`StartTimeTicks` 重新起流(`PlayerViewModel.restartStream`,带合并窗口,停流方式见 Q20)。

### 4.5.1 优先用服务端给的 `DirectStreamUrl` 🔶

来源:Emby Web 4.9.5.0 抓包(Emby Web 原样请求这个地址)。自拼 4.5 的 URL 在部分带网关的服务器上
拿到 200 + JSON 错误体(GitHub issue #2)。形如
`/videos/{id}/original.mkv?DeviceId=..&MediaSourceId=..&PlaySessionId=..&api_key=..`:

- 相对路径**相对 API 根**(`baseURL` + `apiPathPrefix`),已带前缀的不重复加;绝对地址原样采用;
- **剥掉 `api_key`**:认证走请求头(第 6 节);
- 解析不了才退回 4.5。

### 4.6 外挂字幕 ✅

`/Videos/{Id}/{MediaSourceId}/Subtitles/{Index}/Stream.{srt|vtt}`,仅 `IsTextSubtitleStream == true` 时可用。
图形字幕(PGS / VOBSUB)没有下载端点。目前不用外挂字幕(M4)。

## 5. 播放上报 ✅

| 方法 | 路径 | 时机 |
|---|---|---|
| POST | `/Sessions/Playing` | 开始 |
| POST | `/Sessions/Playing/Progress` | 进度(多一个 `EventName`) |
| POST | `/Sessions/Playing/Stopped` | 停止 |

### 5.1 请求体

`ItemId`、`MediaSourceId`、`PlaySessionId`、`PlayMethod`(`DirectStream` / `Transcode`)、`PositionTicks`、
`IsPaused`、`IsMuted`、`VolumeLevel`(0–100)、`CanSeek`(Transcode 为 false)、`AudioStreamIndex`、
`SubtitleStreamIndex`(对不齐就整键省略,Q21)、`QueueableMediaTypes`(`["Video"]`)、`PlaybackRate`。
`SubtitleOffset` ⚠️ 不发:官方没写单位(Q39)。

### 5.2 EventName

定时 / 拖动结束 `TimeUpdate`;`Pause` / `Unpause`;`AudioTrackChange`;`SubtitleTrackChange`;
`VolumeChange`;`PlaybackRateChange`(滑块拖动要合并,只发最后一次)。

### 5.3 频率

定时 **10 秒**(官方:服务端自己按秒推进,不必更频繁);⛔ 不改成 1–2 秒;用户交互立即补一次。

### 5.4 串行化

所有上报经 actor(`PlaybackProgressReporter`)串行,带 generation;切媒体 / 切服务器 generation +1,
丢弃旧代次结果。失败不阻塞播放、不弹窗。关窗后要等 Stopped 真发完(`drain()`)再重读详情(Q22)。

### 5.5 标记已看 ✅

`POST` / `DELETE /Users/{UserId}/PlayedItems/{Id}`,响应 `UserItemDataDto`。

### 5.6 收藏 ✅

`POST` / `DELETE /Users/{UserId}/FavoriteItems/{Id}`,响应 `UserItemDataDto`。

### 5.7 移出继续观看 🔶

`POST /Users/{UserId}/Items/{Id}/HideFromResume?Hide={true|false}`,来源 Emby Web 4.9.5.0 抓包,**不在官方 OpenAPI 里**。
不带 `Hide` 200 但不生效;GET 404。只隐藏不清进度;响应里没有「已隐藏」标记 →
⛔ 客户端不自己维护隐藏清单。4.7.11.0 上是否存在未核实(Q33)。

> ⛔ 5.5–5.7 是写操作,开发者手工验证只在本地实例上点。

## 6. 认证头交给内核

`PlaybackPlan.headers`(第 2 节的 `Authorization` + `X-Emby-Token`)必须真正传给内核,否则播放 401。
内核侧细节见 `MPV_INTEGRATION.md` §5。

### 6.1 首选:`http-header-fields`

`Authorization` 值自带逗号 → 用 `MPV_FORMAT_NODE` 数组设置,**`mpv_initialize()` 之后、`loadfile` 之前**;
⛔ 不拼成一个字符串整体赋值。实测两个 HTTP 连接都原样携带。

### 6.2 退路:`api_key`

仅在**确证**头没到达服务端时,才允许在**播放 URL** 上加 `api_key`;该 URL 只在内存里,日志经 `SecretRedactor`。

### 6.3 禁止

⛔ 不全局关闭 TLS 校验(`tls-verify=no` 之类)。

## 7. HTTP 状态码映射(`EmbyAPIError`,所有端点共用)

| 状态 | case | UI |
|---|---|---|
| 401 | `.unauthorized` | 见 2.5 |
| 403 | `.forbidden` | 权限不足,**不**清 token(禁用账户也是 403) |
| 404 | `.notFound` | 内容不存在 |
| 429 | `.rateLimited` | 稍后重试 |
| 5xx | `.server` | 服务器错误 + 重试 |
| 其他非 2xx | `.unexpectedStatus` | 通用错误 |

另有 `.decoding(underlying:endpointName:)`、`.transport(URLError.Code)`、`.cancelled`。
`URLError.cancelled` → `.cancelled`,UI **不显示为错误**。错误消息可含 host 与状态码,⛔ 不含带认证参数的 URL。

## 8. 解码

### 8.1 可选性

除下表外一律可选。必填(缺失抛 `.decoding`):认证响应 `AccessToken` / `User.Id`;`BaseItem` 的 `Id` / `Name`;`MediaSource.Id`。
⛔ 可选字段不 `!`;⛔ 模型层不填假默认值(`Name ?? "未知"`),缺省值只在 UI 层决定。

### 8.2 命名

统一显式 `CodingKeys`,⛔ 不用自动 PascalCase 转换(`Pw` / `Id` / `IsHD` 会悄悄失配成 nil)。

### 8.3 时间

ticks ↔ 秒只在 `TickConverter`(1 秒 = 10⁷ ticks),⛔ 业务代码不出现该字面量。

## 9. Fixture

### 9.1 位置

`LumaPlayerTests/Fixtures/{Auth,Items,Playback,System,UserData,Views}/`。

### 9.2 命名

`{场景}_{变体}.json`,全小写下划线。

### 9.3 脱敏(强制)

| 原始 | 替换为 |
|---|---|
| `AccessToken` / `api_key` / `X-Emby-Token` | `"FAKE_TOKEN_0123456789"` |
| 用户名 | `"testuser"` |
| host / 域名 | `"emby.test"` |
| `Path` | `"/media/test/sample.mkv"` |
| 用户 Id / 服务器 Id | 固定假 UUID |
| 密码字段 | 整个键删除 |

⛔ 含真实 token 的文件不进 git(`.gitignore` 含 `*.real.json`)。自检命令见 `CLAUDE.md`。

### 9.4 构造数据

⛔ 不手写编造的 fixture 冒充真实响应。确需构造:文件名加 `_synthetic`,测试注释写明「未经真实服务器验证」。
synthetic fixture 只能证明「解码器与你的假设一致」(`Latest` 裸数组就是这么漏的,Q23)。

## 10. 术语

| 用 | 不要叫成 |
|---|---|
| **Item**(电影 / 剧集 / 季 / 分集都是) | Media、Video、Content |
| **Movie / Series / Season / Episode** | 剧、片、节目 |
| **View**(`/Views` 返回的入口) | Library、Folder |
| **MediaSource** | Source、File |
| **MediaStream**(UI 文案可说「轨道」) | Track |
| **DirectStream** | Direct Play、直连 |
| **Transcode** | — |
| **ServerProfile** | Server、Account |
| **PlaySessionId** | SessionId |
| **PlaybackPlan** | Strategy、Decision |
