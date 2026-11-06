# TMDB 接口(本项目用到的部分)

> 本文件是 **TMDB 接口的唯一事实来源**,与 `API_CONTRACT.md`(Emby)、
> `BAIDU_PAN_API.md`(百度网盘)平行。
> 硬规则同 CLAUDE.md 1:**禁止发明接口**,只用本文件列出的端点 / 参数 / 字段。
>
> 字段与端点**逐条对着 TMDB 官方 OpenAPI 规格核实**:
> 文档站 `developer.themoviedb.org` 的响应字段在页面上是 JS 渲染的,抓不到,
> 所以取它同一站点公开的规格文件
> `https://developer.themoviedb.org/openapi/tmdb-api.json`(OpenAPI 3.1.0),
> 由 `paths./3/search/movie`、`paths./3/search/tv`、
> `paths./3/tv/{series_id}/season/{season_number}`(§7)直接读出参数字段与响应 schema ——
> 这是官方产物,不是二手转述。认证方式与错误码另对着
> `docs/authentication-application`、`docs/errors`、`docs/image-basics` 核实。

## 1. 主机与认证

| 主机 | 用途 |
|---|---|
| `api.themoviedb.org` | 元数据接口(搜索等) |
| `image.tmdb.org` | 图片 CDN(`/t/p/...`,见 §4) |

**认证**:v4 **Read Access Token** 走请求头

```
Authorization: Bearer <API Read Access Token>
```

⚠️ 这就是官方说的「默认认证方式」:账号 API 设置页里那串 *API Read Access Token*,
作为 `Authorization` 头整体送出。它同时可用于 v3 与 v4 方法,权限一致。
⛔ 本项目**不用** `api_key` 查询参数那条路 —— token 落查询串会被写进 URLSession 的
缓存 / 日志,与百度 `access_token` 同一个理由(`BaiduPanAPIClient` 的注释)。

请求另建议带 `Accept: application/json`(官方 cURL 示例带它)。

> **本项目的 token 由用户在设置页输入**,存进凭据文件(0600、不进备份),
> 与百度凭据同处(`CredentialStore`)。⛔ 不进 UserDefaults、不进仓库。

## 2. 搜索端点

两个端点都用同一个查询参数形状(官方规格):

`GET /3/search/movie`

| 参数 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `query` | string | ✅ | — | 搜索词(标题) |
| `include_adult` | boolean | | `false` | |
| `language` | string | | `en-US` | ISO 639-1 + ISO 3166-1,如 `zh-CN` |
| `primary_release_year` | string | | — | 只看首次上映年 |
| `page` | int32 | | `1` | |
| `region` | string | | — | |
| `year` | string | | — | 限定年份 |

`GET /3/search/tv`

| 参数 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `query` | string | ✅ | — | 搜索词(剧名) |
| `first_air_date_year` | int32 | | — | 只看首播年 |
| `include_adult` | boolean | | `false` | |
| `language` | string | | `en-US` | |
| `page` | int32 | | `1` | |
| `year` | int32 | | — | 首播年**及所有分集播出年** |

⚠️ 本项目首轮只用 `query` + (`year` / `first_air_date_year`) + `language=zh-CN`。
解析不出年份时不传年份参数(⛔ 不填 `0` / 空串这类假默认值)。

> 为什么摘要是「电影」「剧」两个端点而不是一个:电影侧字段叫 `title` / `release_date`,
> 剧侧叫 `name` / `first_air_date`(`BaiduPanMetadataSynthesizer` 能从文件名判出季集 →
> 有季集走 `/search/tv`,否则走 `/search/movie`)。两个响应各解各的。

## 3. 响应字段(本项目真正读的)

两个端点**顶层**都同形(官方规格):

```
page:int  results:[…]  total_pages:int  total_results:int
```

`results[]` 一个条目:

| 字段 | 类型 | movie | tv |
|---|---|---|---|
| `id` | int | ✅ TMDB 条目 id | ✅ |
| `title` / `name` | string | `title` | `name` |
| `original_title` / `original_name` | string | ✅ | ✅ |
| `overview` | string | ✅ 简介 | ✅ |
| `poster_path` | string | ✅ 海报相对路径(可能为 `null`) | ✅ |
| `release_date` / `first_air_date` | string | `release_date` | `first_air_date` |
| `vote_average` | number | ✅ 评分 | ✅ |
| `vote_count` | int | ✅ | ✅ |
| `adult` / `backdrop_path` / `genre_ids` / `original_language` / `popularity` | — | ✅ | ✅ |
| tv 独有 | | | `origin_country:[String]` |

⚠️ **解码立场**:除 `id` 外一律**可选**。TMDB 对没有海报 / 没有上映日的条目会返回
`null`(官方示例里 `poster_path` 就是普通字符串,但真实数据存在 `null`),
把它们写成必填会让整条解失败 —— 与百度侧「能缺的字段一律可选、⛔ 不填假值」同口径。
日期串 `YYYY-MM-DD` 取前 4 位当年份;解不出来就是 `nil`。

## 4. 图片

官方 `docs/image-basics` 的三段拼法:

```
https://image.tmdb.org/t/p/{file_size}/{file_path}
```

`file_path` 就是条目上的 `poster_path`(形如 `/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg`)。
`file_size` 是规格里的档位(如 `w500`、`w342`);本项目海报用 `w500`。
`base_url` 与可用档位理论上由 `/3/configuration` 给,但规格对 `image.tmdb.org` 的
固定拼法已足够,⛔ 不为一个常量多发一次请求(与百度「少发请求」同一取舍)。

> `poster_path` 自带版本语义(换了海报 TMDB 会换路径),所以它可直接进
> `ImageDescriptor.cacheKey`(见 `ImageDescriptor` 的缓存硬规则)。

## 5. 错误码(本项目会处置的)

官方 `docs/errors`:

| status_code | HTTP | 含义 |
|---|---|---|
| `1` | 200 | 成功 |
| `3` | 401 | 认证失败:无权访问该服务 |
| `7` | 401 | API key 无效 |
| `25` | 429 | 超过频率上限(请求数超 40/秒量级) |
| `34` | 404 | 请求的资源找不到 |
| `35` | 401 | token 无效 |
| `9` | 503 | 服务临时离线(可重试) |
| `11` | 500 | 内部错误 |

失败响应体(**官方规格的 401 示例**):

```json
{"status_code":7,"status_message":"Invalid API key: You must be granted a valid key.","success":false}
```

⇒ 映射规则:HTTP **401** → 「token 无效或未填」(要用户去设置页检查);
HTTP **429** → 「请求过于频繁,稍后重试」;其余非 2xx → 带状态码的通用失败。
`status_message` 取来一起展示(它不含凭据)。

## 6. 频率限制

官方 `docs/rate-limiting`:请求数上限约 **40 次/秒**量级(按 IP)。
本项目自用一个 token,刮削是**低频**动作(一次浏览目录最多几个文件名),
正常远不触顶;⛔ 不做后台轮询、不做逐条串行轰炸。

## 7. 季详情端点(取分集)

`GET /3/tv/{series_id}/season/{season_number}`

同一个官方规格文件的 `paths./3/tv/{series_id}/season/{season_number}` 读出:

| 参数 | 位置 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|---|
| `series_id` | path | int32 | ✅ | — | 剧的 TMDB id(§3 里 `results[].id`) |
| `season_number` | path | int32 | ✅ | — | 季号。特别篇是 `0` |
| `language` | query | string | | `en-US` | 同 §2 |
| `append_to_response` | query | string | | — | ⛔ 本项目不用 |

⚠️ **为什么需要它**:`/3/search/tv` 只给**剧级**信息(海报 / 简介 / 首播年),
分集的**剧照 / 集名 / 单集简介**只有这个端点给(`episodes[]`)。
没有它就只能拿剧海报去配每一集 —— 那正是「每张卡都是同一个封面」的成因。

**响应顶层**(官方规格):`_id`、`air_date`、`name`、`overview`、`id`、
`poster_path`、`season_number`、`vote_average`、`episodes:[…]`(顶层 `air_date` 本项目不读)。

`episodes[]` 每项(官方规格):

| 字段 | 类型 | 说明 |
|---|---|---|
| `episode_number` | int | 季内集号,回填时**按它匹配** |
| `name` | string | 集名(可能为空串) |
| `overview` | string | 单集简介(**可能为 `null`**) |
| `still_path` | string | 分集剧照相对路径(可能为 `null`) |
| `air_date` | string | 单集播出日 `YYYY-MM-DD`(未播出的集可能为 `null` / 空串) |
| `runtime` | int | 单集片长(分钟,可能为 `null`) |
| `vote_average` | number | 单集评分(可能为 `null`) |
| `episode_type` / `id` / `season_number` / `show_id` / `production_code` / `vote_count` / `crew` / `guest_stars` | — | 本项目不读 |

⚠️ 解码立场同 §3:**除 `episode_number` 外一律可选**。`name` 遇到空串当「没有集名」,
⛔ 不用空串冒充,也⛔ 不解码失败。

**季不存在**时返回 404(`status_code: 34`,见 §5)→ 折成 `.notFound`;
这是**确定性**答案(这一季就是没有),可以记住不再重问。

## 8. 分集剧照(still)

拼法与 §4 完全一致,只是路径来自 `episodes[].still_path`:

```
https://image.tmdb.org/t/p/{file_size}/{still_path}
```

⚠️ 剧照是 **16:9 横图**,与海报(2:3 竖图)不是一个形状;档位本项目用 `w300`
(卡片宽度量级)。⛔ 别拿海报的 `w500` 当剧照档位 —— 那是按竖图挑的。
`still_path` 与 `poster_path` 同样**自带版本语义**,可直接进 `ImageDescriptor.cacheKey`。

## 9. 按 id 直取端点(跳过搜索)

`GET /3/tv/{series_id}` 与 `GET /3/movie/{movie_id}`

同一个官方规格文件读出:

| 参数 | 位置 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|---|
| `series_id` / `movie_id` | path | int32 | ✅ | — | TMDB 条目 id |
| `language` | query | string | | `en-US` | 同 §2 |
| `append_to_response` | query | string | | — | ⛔ 本项目不用 |

**为什么需要它**:文件名 / 目录名里**显式写死**了 TMDB id 时(标准命名
`一拳超人 (2015) {tmdbid-63926}`,见 `docs/KNOWN_ISSUES.md`),再按标题搜一遍
既慢又可能搜错(中英混排标题 + 年份根本对不上)。有 id 就直接取。

⚠️ **响应体形状**:与 §3 的 `results[]` 条目**同字段名**(电影 `title` /
`release_date`,剧 `name` / `first_air_date`),但**顶层就是条目本身**,没有
`results` 包装 —— 所以能解进同一个 `TMDBResult`。解码立场同 §3:除 `id` 外一律可选。

⚠️ **id 不区分影 / 剧**:TMDB 的两个 id 空间各自编号,同一个数字在两边可能是
**两部不同的作品**。标签本身只说「是这个 id」,查哪个端点由调用方按上下文决定
(`BaiduPanMetadataScraper`:剧集条目按剧查;目录卡片先剧后影;单条视频先影后剧)。
id 在该端点不存在时返回 404(`status_code: 34`,见 §5)→ 折成 `.notFound`,
是**确定性**答案,可以记住不再重问。

**响应字段(对着同一份官方 OpenAPI 规格核实)**:

| 字段 | 类型 | tv | movie | 说明 |
|---|---|---|---|---|
| `id` / `name` / `title` / `overview` / `poster_path` | — | ✅ | ✅ | 同 §3 |
| `first_air_date` / `release_date` | string | ✅ | ✅ | 首播 / 上映日 |
| `vote_average` / `vote_count` | number / int | ✅ | ✅ | 评分 |
| `genres[]` | `{id,name}` | ✅ | ✅ | **类型名**。⚠️ 搜索响应里只有 `genre_ids`(数字),没有名字 —— 要显示类型就得走这个端点 |
| `tagline` | string | ✅ | ✅ | 标语(可能为空串) |
| `status` | string | ✅ | ✅ | 剧:`Returning Series` / `Ended`;电影:`Released` / `Rumored` 等 |
| `production_companies[]` | `{id,name,logo_path,origin_country}` | ✅ | ✅ | 制片公司 |
| `networks[]` | `{id,name,logo_path,origin_country}` | ✅ | ⛔ | 电视台(电影侧没有这个字段) |
| `number_of_seasons` / `number_of_episodes` | int | ✅ | ⛔ | 全剧总季数 / 总集数。**只作展示**(详情页「共 N 集 / 共 N 季」与「信息」区),⛔ 不覆盖网盘目录里实际存的东西、不参与分集列表与换集队列 |
| `last_air_date` | string | ✅ | ⛔ | 完结日 / 最后播出日 |
| `episode_run_time` | `[int]` | ✅ | ⛔ | 单集片长(分钟) |
| `runtime` | int | ⛔ | ✅ | 片长(分钟) |
| `backdrop_path` | string | ✅ | ✅ | 横版背景图相对路径(可能为 `null`)→ 走 §4 的 `w1280` 档;详情页 hero 用它,⛔ 不再拿竖版海报放大模糊 |
| `homepage` / `popularity` / `original_language` / `production_countries` / `spoken_languages` / `adult` | — | ✅ | ✅ | 本项目不读 |

## 10. 演职员端点(演员列表 / 主创)

剧集用 `GET /3/tv/{series_id}/aggregate_credits`,电影用 `GET /3/movie/{movie_id}/credits`。
同一份官方 OpenAPI 规格读出:

| 参数 | 位置 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|---|
| `series_id` / `movie_id` | path | int32 | ✅ | — | 剧 / 电影的 TMDB id |
| `language` | query | string | | `en-US` | 同 §2 |

⚠️ **为什么剧集必须用 `aggregate_credits`**:`/3/tv/{id}/credits` 的官方描述是
「Get the **latest season** credits of a TV show」—— 只给**最新一季**,前几季的常驻 / 客串
演员根本不在响应里。`aggregate_credits` 的描述是「Get the **aggregate credits** ... added
to a TV show」,才与官网剧集页那份完整演员表一致。两者差的不是形状而是**数据范围**,⛔ 不要为了
「`character` 是单个字符串好解析」退回 `credits`。电影侧没有 aggregate 端点,仍用 `credits`。

⚠️ **为什么需要它**:`/3/search/*` 与 `/3/{tv\|movie}/{id}` 都**不给**演职员,
而详情页要展示演员列表与主创。

**响应顶层**:`id`、`cast:[…]`、`crew:[…]`(两个端点同形)。

**电影 `credits` 的 `cast[]`**:

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | int | 人物的 TMDB id |
| `name` | string | 演员名 |
| `character` | string | 角色名(可能为空串) |
| `profile_path` | string | 头像相对路径(**可能为 `null`**)→ 走 §4 拼法 |
| `order` | int | TMDB 给的主要程度排序(0 起) |

**剧集 `aggregate_credits` 的 `cast[]`**:没有 `character`,改成

| 字段 | 类型 | 说明 |
|---|---|---|
| `roles[]` | `{credit_id, character, episode_count}` | 同一演员跨季演过的角色;本项目取 `roles[0].character` 作角色名 |
| `total_episode_count` | int | 参演总集数,展示用(如「参演 62 集」) |
| `id` / `name` / `profile_path` / `order` | — | 同电影侧 |

**电影 `credits` 的 `crew[]`**:

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` / `name` / `profile_path` | — | 同 `cast[]` |
| `job` | string | 职务(`Director` / `Writer` / `Producer` / …) |
| `department` | string | 部门(`Directing` / `Writing` / `Production` / …) |

**剧集 `aggregate_credits` 的 `crew[]`**:没有单个 `job`,改成 `jobs[]`
(`{credit_id, job, episode_count}`);本项目取 `jobs[0].job` 作职务,`department` 与
`total_episode_count` 同样在。⚠️ 一人兼多职时只展示第一个 job,其余不摊成多张卡。

两侧都不读:`known_for_department` / `original_name` / `popularity` / `gender` / `adult` / `credit_id`。

⚠️ **解码立场同 §3**:除 `id` 外一律可选 —— 真实数据里角色名可能是空串、
`profile_path` 可能是 `null`、`roles[]` / `jobs[]` 可能是空数组。⛔ 不写成必填(会让整条解失败)。

⚠️ **顺序按 TMDB 给的 `order`**,客户端只排序、⛔ 不自己重排主要程度;`crew` 没有 `order`,按响应原序。

⚠️ 分季 / 分集的演职员另有 `/3/tv/{id}/season/{n}/credits` 与
`/3/tv/{id}/season/{n}/episode/{e}/credits`,本项目不用。

## 12. 图片集合端点(§4 之外的多图)

`GET /3/tv/{series_id}/images`、`GET /3/tv/{series_id}/season/{season_number}/images`、
`GET /3/tv/{series_id}/season/{season_number}/episode/{episode_number}/images`、
`GET /3/movie/{movie_id}/images`

同一份官方 OpenAPI 规格读出:

| 参数 | 位置 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|---|
| `series_id` / `movie_id` | path | integer | ✅ | — | 剧 / 电影的 TMDB id |
| `season_number` / `episode_number` | path | integer | ✅(分季 / 分集端点) | — | 季号 / 集号 |
| `language` | query | string | | `en-US` | 同 §2 |
| `include_image_language` | query | string | | — | 逗号分隔的语言码;⛔ 本项目不传(拿官方给的全部候选) |

**响应顶层**:`id` 加以下数组,各端点给哪些不同:

| 端点 | 顶层数组 |
|---|---|
| `/3/tv/{id}/images` | `backdrops[]`、`posters[]`、`logos[]` |
| `/3/tv/{id}/season/{n}/images` | `posters[]` |
| `/3/tv/{id}/season/{n}/episode/{e}/images` | `stills[]` |
| `/3/movie/{id}/images` | `backdrops[]`、`posters[]`、`logos[]` |

每个数组元素(`file_path` 必填,其余可选):

| 字段 | 类型 | 说明 |
|---|---|---|
| `file_path` | string | 图片相对路径 → 走 §4 拼法 |
| `width` / `height` / `aspect_ratio` | int / int / number | 原始尺寸与宽高比 |
| `iso_639_1` | string 或 null | 语言码;`backdrops[]` / `stills[]` 可能是 `null` |
| `vote_average` / `vote_count` | number / int | 社区评分,⛔ 本项目不按它排序(按响应原序) |

⚠️ **解码立场同 §3**:`file_path` 之外一律可选;数组本身也可能缺 / 为空,空数组 = 这一类没有候选图。

⚠️ **档位**(官方 `/3/configuration` 的 200 示例,本项目写死,⛔ 不为常量发请求):
`backdrop_sizes = [w300, w780, w1280, original]`、`poster_sizes = [w92, w154, w185, w342, w500, w780, original]`、
`still_sizes = [w92, w185, w300, original]`、`logo_sizes = [w45, w92, w154, w185, w300, w500, original]`。
本项目背景图用 `w1280`、海报墙用 `w500`、剧照墙用 `w300`、logo 用 `w300`。

⚠️ **请求纪律(硬约束)**:分集 `/images` 是**每集一次**请求。⛔ 进详情页不为整季批量拉,
只在用户点开某一集的图片时才发;季 `/images` 同理只在点开「季海报」时发。
结果按端点缓存(进程内),重复查看零请求;换剧 / 换授权时清空。

⚠️ `backdrop_path` 仍由 §9 详情端点给(单张主图),零额外请求;§12 的多图集合是**补充**,不替代它。

## 11. 人物头像(profile)

拼法与 §4 一致,路径来自 `cast[].profile_path` / `crew[].profile_path`:

```
https://image.tmdb.org/t/p/{file_size}/{profile_path}
```

档位本项目用 **`w185`**(头像卡片约 75pt 宽,与 `w500` 海报 / `w300` 剧照同一量级取舍)。
`profile_path` 与 `poster_path` 一样**自带版本语义**,可直接进 `ImageDescriptor.cacheKey`。
