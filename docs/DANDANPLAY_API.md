# 弹弹play 开放平台接口(本项目用到的部分)

> 本文件是**弹弹play 接口的唯一事实来源**,与 `API_CONTRACT.md`(Emby)、`BAIDU_PAN_API.md`、
> `TMDB_API.md` 平行。硬规则同 CLAUDE.md 1:**禁止发明接口**,只用本文件列出的端点 / 参数 / 字段。
>
> 核实来源(2026-10-15):
> - 官方 OpenAPI 3.0 规格 `https://api.dandanplay.net/swagger/v2/swagger.json`(`info.version = v2`),
>   端点、参数、请求体 / 响应 schema 由 `paths` 与 `components.schemas` 直接读出;
> - 官方文档站 `https://doc.dandanplay.com/open/`:认证方式、状态码、缓存与使用约定。
>
> ⚠️ **本机没有弹弹play 应用凭据,下列接口全部只有 mock 覆盖,未在真实服务验证**(`KNOWN_ISSUES.md` Q45 - Q47)。

## 1. 主机与认证

主机:`https://api.dandanplay.net`。

**签名模式**(官方推荐客户端应用使用,本项目只用这一种):

```
X-AppId:     {AppId}
X-Timestamp: {Unix 时间戳,秒,UTC}
X-Signature: base64(sha256(AppId + Timestamp + Path + AppSecret))
```

- `Path`:以 `/` 开头,**不含**协议、域名、查询串,例如 `/api/v2/comment/123450001`;
  官方建议「路径全部使用小写字母,不需要经过 URL 编码」。
- 拼接区分大小写、无分隔符;SHA-256 后 Base64。
- 时间戳与服务器偏差过大会 403。

⛔ **不用凭证模式**(`X-AppId` + `X-AppSecret` 头直接带密钥):官方说那是给能保护密钥的服务端用的。

**凭据来源**:开发者在 `dev.dandanplay.com` 注册、创建应用、审核通过后获得 1 个 AppId 与 2 个 AppSecret。
官方要求不要把 AppSecret 硬编码进客户端。本项目没有服务器可代签名 →
**由用户在「设置 › 弹幕」自填**,存凭据文件(`CredentialStore`,0600、不进备份),⛔ 不进 UserDefaults、不进仓库。

**状态码**:

| 码 | 含义 | 映射 |
|---|---|---|
| 401 | 调用受限接口时缺身份验证头 | `DandanplayError.unauthorized` |
| 403 | 时间戳无效 / 偏差过大、AppId / AppSecret 无效、签名不符;所有页面都 403 时可能 IP 被屏蔽。响应头 `X-Error-Message` 给原因(如 `Invalid Timestamp`、`Invalid Signature`) | `.forbidden(reason:)` |
| 其它非 2xx | | `.server(statusCode:)` |

带 `ResponseBase` 的响应(match / search / bangumi)HTTP 200 时还要看 `success`:
`errorCode`(int,0 = 无错)、`success`(bool)、`errorMessage`(string?)、`errorDetail`(string?)。
`success == false` → `.api(code:message:)`。

## 2. 文件识别 `POST /api/v2/match`

请求体 `MatchRequest`(规格里**没有** required 字段):

| 字段 | 类型 | 说明 | 本项目 |
|---|---|---|---|
| `fileName` | string? | 视频文件名,**不含文件夹名与扩展名** | 百度:真实文件名去扩展名;Emby:合成(见 `DanmakuMediaQuery`) |
| `fileHash` | string? | 文件前 16 MB 的 MD5(32 位,不区分大小写) | **不传**(拿字节要多拉 16 MB) |
| `fileSize` | int64 | 文件总长度(字节) | 百度有就传;Emby 不传 |
| `videoDuration` | int32 | [可选] 时长(秒),默认 0 | 播放器已知时传 |
| `matchMode` | enum | `hashAndFileName` / `fileNameOnly` / `hashOnly` | 恒 `fileNameOnly` |

响应 `MatchResponseV2` = `ResponseBase` +:

- `isMatched`(bool):**已精确关联** —— 此时 `matches` 只有一项,官方:「客户端应自动选择这个唯一的结果」;
- `matches`(`MatchResultV2[]?`,按可能性降序):
  `episodeId`(int64,弹幕库 id)、`animeId`(int64)、`animeTitle`?、`episodeTitle`?、
  `type`(`AnimeType` 枚举字符串)、`typeDescription`?、`shift`(double,**弹幕应延迟多少秒出现,负数为提前**)、`imageUrl`?。

本项目:`isMatched` → 直接采用;否则把候选交给用户挑(⛔ 不自动取第一个模糊结果)。
`POST /api/v2/match/batch`(只返回精确关联,≤ 32 个)存在但**不用**。

## 3. 关键词搜索 `GET /api/v2/search/episodes`

| 参数 | 类型 | 说明 | 本项目 |
|---|---|---|---|
| `anime` | string? | 作品标题,中 / 日(含罗马音)/ 英,**至少 2 个字符** | ✅ |
| `episode` | string? | 集号:正整数或 `C1` / `S1` / `O1`,只保留该集 | 用户填了才传 |
| `tmdbId` | int32? | 只返回该 TMDB id 的关联作品 | 不用(见 `DANMAKU.md` §6) |
| `tmdbIdType` | int32 | 0 / 不传 = 电视剧 id,1 = 电影 id | 不用 |
| `v2` | bool | 新版搜索引擎 | 不用 |

`anime` 与 `tmdbId` 至少提供一个。⚠️ `anime` 里「空格 + 数字」(`EVA 10`)在未给 `episode` 时会被当成集号。

响应 `SearchEpisodesResponse` = `ResponseBase` +:`hasMore`(bool,结果过多被截断,应提示用户写得更具体)、
`animes`(`SearchEpisodesAnime[]?`):`animeId`、`animeTitle`?、`type`、`typeDescription`?、
`episodes`(`SearchEpisodeDetails[]?`:`episodeId`、`episodeTitle`?)。

## 4. 作品详情 `GET /api/v2/bangumi/{bangumiId}`

`bangumiId` 支持数字 `animeId`。无需登录。响应 `BangumiDetailsResponse` = `ResponseBase` + `bangumi`(`BangumiDetails?`)。

本项目只读:`bangumi.animeId`、`bangumi.animeTitle`、`bangumi.episodes`(`BangumiEpisode[]?`):
`episodeId`(int64)、`episodeTitle`?、`episodeNumber`?(**剧集短标题,可以排序,不一定是纯数字,可能含字母**)、
`seasonId`?(空 = 只有一季)。

用途:一部剧绑定到某作品后,按集号在这里找其它集(`DanmakuService.episode(number:in:)`:
只认能解析成整数且**唯一**相等的一项,对不上 / 有重复就不选)。

## 5. 获取弹幕 `GET /api/v2/comment/{episodeId}`

| 参数 | 类型 | 默认 | 说明 | 本项目 |
|---|---|---|---|---|
| `episodeId` | int64(path) | | 弹幕库编号 | |
| `from` | int64 | 0 | 起始弹幕编号 | 不传 |
| `withRelated` | bool | false | 同时获取关联的第三方弹幕(官方推荐 true) | `true` |
| `chConvert` | int32 | 0 | 0 不转换 / 1 转简体 / 2 转繁体 | `1` |

⚠️ 规格里此端点的响应是 **302**:跳到弹幕加速服务,`Location` 给地址;URLSession 默认跟随。

响应 `CommentResponseV2`(**没有** `ResponseBase`):`count`(int32)、`comments`(`CommentData[]?`):
`cid`(int64)、`p`(string?)、`m`(string?,弹幕内容)。

`p` = `出现时间,模式,颜色,用户ID`:
- 出现时间:秒,两位小数(如 `12.34`);
- 模式:`1` 普通(滚动)、`4` 底部、`5` 顶部;
- 颜色:32 位整数,`R×256×256 + G×256 + B`;
- 用户 ID:字符串。

解析不了的条目(字段不够、数字非法、未知模式、空文本)**丢弃并计数**,在播放页菜单如实显示。

## 6. 使用约定(官方)

- 「请缓存 API 返回的数据」;弹幕、节目信息、搜索结果都变动少,建议缓存 **2 - 6 小时**
  (热门新番更新当天可缩短)。本项目弹幕磁盘缓存 4 小时(`DanmakuCommentCache`),作品剧集列表进程内记忆。
- 目前不限调用频率,但搜索、获取弹幕等耗资源的接口有滥用检测;自 2026-06-25 起有应用分层与额度管理。
  → 搜索**只在用户点按钮时**发一次,⛔ 不做边输边搜。
- 发送弹幕(`POST /comment/{episodeId}/app`)、用户相关接口:**不用**(本项目只读)。
