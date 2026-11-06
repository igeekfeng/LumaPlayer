# 百度网盘开放平台接口(本项目用到的部分)

> 本文件是**百度网盘接口的唯一事实来源**,与 `API_CONTRACT.md`(Emby)平行。
> 硬规则同 CLAUDE.md 1:**禁止发明接口**,只用本文件列出的端点 / 参数 / 字段。
> 字段与错误码来自百度开放平台官方页(设备码授权 / 文件列表 / 播放流 / 错误码),
> 部分条目带「实测」标记 —— 那些是在真实应用上抓包/调用核实过的,
> 与官方页不一致时**以实测为准**,并在本文件里写明差异。

## 1. 两个主机与认证方式

| 主机 | 用途 |
|---|---|
| `openapi.baidu.com` | OAuth:设备码、换 token、刷新 |
| `pan.baidu.com` | 网盘业务:用户信息、列表、元信息、播放流 |

**认证与 Emby 相反**:`access_token` 放在**查询串**上,不放请求头。
唯一要自己挂的头是 `User-Agent`:

- 列表 / 元信息 / 下载:一律 `User-Agent: pan.baidu.com`(不给会撞 `31326` 防盗链);
- 播放流:`User-Agent: xpanvideo;<app>;<ver>;<sys>;<sysver>;ts`(两者⛔不可互换)。

查询串**手拼**,不用 `URLComponents.queryItems` —— 后者按 RFC 3986 只编码非法字符,
`/` 会被原样留下,而百度要求 `path` / `dir` **整体**编码(`/apps/x` → `%2Fapps%2Fx`)。
只保留 unreserved 字符(`A-Za-z0-9-._~`),与官方 cURL 示例的 `--data-urlencode` 同口径。

## 2. 端点

### 2.1 OAuth(`openapi.baidu.com`)

| 用途 | 端点 |
|---|---|
| 取设备码 | `GET /oauth/2.0/device/code?response_type=device_code&client_id=&scope=basic,netdisk` |
| 设备码换 token | `GET /oauth/2.0/token?grant_type=device_token&code=&client_id=&client_secret=` |
| 刷新 token | `GET /oauth/2.0/token?grant_type=refresh_token&refresh_token=&client_id=&client_secret=` |

设备码响应的 `qrcode_url` 是**图片地址**,不是要编进二维码的内容;
要编进二维码的是 `https://openapi.baidu.com/device?display=mobile&code=<user_code>`
(官方页写明的拼接规则),本项目本地用 CoreImage 渲染,不下载那张图。

轮询间隔⛔不得小于 5 秒(官方原话「一般不能低于 5 秒」),有效期 300 秒。

### 2.2 网盘(`pan.baidu.com`)

| 用途 | 端点 |
|---|---|
| 账号信息 | `GET /rest/2.0/xpan/nas?method=uinfo&vip_version=v2` |
| 列目录 | `GET /rest/2.0/xpan/file?method=list&dir=&start=&limit=&order=name` |
| 文件元信息(**含 dlink**) | `GET /rest/2.0/xpan/multimedia?method=filemetas&fsids=[fs_id]&dlink=1&needmedia=1&thumb=1` |
| 播放流 | `GET /rest/2.0/xpan/file?method=streaming&path=&type=[&nom3u8=1][&adToken=]` |

⚠️ **`method=list` 的响应里没有总数字段**(既无 `total` 也无 `has_more`)——
那两个是 `method=listall` 的字段。⇒ 目录总数拿不到,详见 §7.2。

**实测差异(重要)**:文档写的元信息路 `file?method=meta&dlink=1` 实测**既没有 `errno`、也没有 `dlink`**。
给 `dlink` 的是 `multimedia?method=filemetas`(带 `errno`,条目带 `dlink` 与 `duration`)。
⇒ **播放入口一律走 `filemetas`**,⛔ 不用 `method=meta`。

`fsids` 是 **JSON 数组字面量**(`[1106099239747639]`),整段编码后送
(实测 `fsids=%5B1106099239747639%5D` 可用)。查文件用 `fs_id` 而不是 `path`:
改名/挪位置后 `path` 会变而 `fs_id` 不变,列表里本来就带着它。

`needmedia=1` 时条目里才有 `duration`(实测直接给在条目上,秒;
**不是**嵌套在 `media_info` 里 —— 见 §4)。

`vip_version=v2` 时 `vip_type` 才是 0 普通 / 1 会员 / 2 超级会员三档。

### 2.3 播放流 `type` 取值

只用**通用 HLS**那一档。`M3U8_FLV_264_*` 与 `M3U8_MP3_128` 是私有协议,
需要网盘自家播放器,AVFoundation / libmpv 不认识。

| 常量 | 值 | 说明 |
|---|---|---|
| 视频 | `M3U8_AUTO_1080` | 按原片自动封顶,不会把 720p 顶上 1080p |
| 音频 | `M3U8_HLS_MP3_128` | 音频只有这一个是通用 HLS |

`nom3u8=1`:只要 JSON 状态不要 m3u8 文本 —— 起播前用它探一次,
把 `133` / `-6` / `31347` 在**建流之前**问出来。

### 2.4 删除(`method=filemanager&opera=delete`)

| 项 | 值 |
|---|---|
| 方法 | `POST https://pan.baidu.com/rest/2.0/xpan/file` |
| 查询串 | `method=filemanager&access_token=&opera=delete` |
| Content-Type | `application/x-www-form-urlencoded` |
| body | `async=0&filelist=["/apps/<APP_NAME>/a.mkv"]` |

`opera` 另有 `copy` / `move` / `rename`,本项目只用 `delete`。`delete`
⛔ 不用 `ondup`(官方注意事项第 4 条明说它不适用于 delete)。

- `async`:`0` 同步、`1` 自适应、`2` 异步。**本项目一律 `0`** —— 异步只回
  `taskid`、`info` 为空,拿不到逐条结果,而删除必须当场知道成没成。
- `filelist`:**路径字符串的 JSON 数组**,不是对象(`copy` / `move` / `rename`
  才是 `{path,dest,newname}`)。一次只删一条时仍是单元素数组。
- 只能操作 `/apps/{应用目录名}` 下的路径(官方「权限说明」把 `filemanager`
  与 `download` / `meta` / `move` 列在一起,⛔ 范围见 §3)。

**响应**:`errno` + `info[].errno` / `info[].path` + `request_id`(异步时另有
`taskid`)。⚠️ 顶层 `errno == 0` **只表示受理**,单条失败在 `info[].errno` 里
(`errno=0` + `info[0].errno=-9` 是常态)—— ⛔ 只看顶层等于静默吞错。

**目录(文件夹)**:官方通篇只写「文件」,没说 `filelist` 能不能放目录路径。
**实测(真实应用)**:可以,而且是**递归删** —— 传一个目录路径,
目录连同里面的全部内容一起没了,非空目录也一样删得掉。
⇒ 本项目据此实现,⛔ 但这是官方未写的行为,改版后要重测。
(空目录 / 非空目录都能删;`-9`「不存在」仍按 §5 处置。)

### 2.5 改名(`method=filemanager&opera=rename`)

| 项 | 值 |
|---|---|
| 方法 | `POST https://pan.baidu.com/rest/2.0/xpan/file` |
| 查询串 | `method=filemanager&access_token=&opera=rename` |
| Content-Type | `application/x-www-form-urlencoded` |
| body | `async=0&filelist=[{"path":"/apps/x/a.mp4","newname":"b.mp4"}]` |

与 `delete` 的两处形状差异:

- `filelist` 是**对象数组** `{path, newname}`(delete 是路径字符串数组);
- rename 只改**最后一段名字**,不改父目录 —— 想挪位置是 `opera=move`(本项目不用)。

`async` 同 §2.4 一律 `0`:要当场拿到逐条结果。

⛔ **不传 `ondup`**:取值与语义无一手依据。目标名冲突由**本地计划阶段**排除
(`BaiduPanRenamePlanner` 做完改名后的同目录占用表),不依赖服务端行为。

响应形状与 §2.4 同一个 `BaiduPanFileManagerResponse`:顶层 `errno` + `info[].errno` / `info[].path`。

### 2.6 改名的顺序约束(本项目的硬约束)

`filelist` 用 `path` 定位,**父目录一改名,子文件的 `path` 立刻失效**。
⇒ 必须**自底向上**分批提交:集文件 → 季目录 → 剧根,每批等回包再开下一批
(`BaiduPanRenamePlanner.Target.order` 就是执行顺序)。

## 2.7 rename 的现有实现假设

以下四条没有一手依据,现有实现只是按「与 delete 同形 + 按位置匹配」的假设写的:

1. 一次 `filelist` 最多能放几条(现按 50 分片,保守值);
2. 是否支持**目录**路径(delete 支持,§2.4;rename 无一手依据);
3. 响应 `info[]` 的**顺序**是否与请求一致、`path` 是旧名还是新名 ——
   现在按位置匹配,并以「条数必须相等」为校验,条数对不上就**整批判失败**
   (⛔ 不猜是哪一条);
4. 改名后 `fs_id` 是否不变(决定本地进度能不能接着用 —— 见 `WatchProgressStore`)。

实测方式:建 `/apps/{应用目录名}/_rename_probe/`,放 2 个文件 + 1 个子目录,
用 App 的「按 TMDB 重命名」对它跑一次,看结果与 `info[]`。只烧 1–3 次配额。

## 3. 授权范围(第三方应用的硬边界)

第三方应用**只能访问** `/apps/{应用目录名}` 下的文件,`{应用目录名}` 必须与
开放平台控制台里的「应用名称」完全一致(含大小写)。可访问范围完全由这一个值决定,
用户改不了。`/apps` 这一层用户自己也建不了(百度把它当保留关键字)。

判断路径是否在范围内用 `root + "/"` 前缀,⛔ 不用 `hasPrefix(root)`
—— 后者会把 `/apps/LumaPlayerXX` 也算进 `/apps/LumaPlayer`,而那类路径一样访问不到。

## 4. 字段表(本项目真正读的)

### 列表条目(`list[]`)

`fs_id`(uint64,见过字符串形式,两种都认)/ `path` / `server_filename` /
`size` / `isdir` / `category`(1 视频 2 音频 3 图片 4 文档 5 应用 6 其他 7 种子)/
`server_mtime` / `thumbs`(`web=1` 时图片才有,本项目不接缩略图)。

### 元信息条目(`filemetas`)

在列表条目基础上多:`dlink`(直连地址,8 小时有效)/ `duration`(秒)/
`filename`(名字字段名与列表不同)。`thumb=1` 才有 `thumbs`。

⚠️ **`media_info` 实测不存在**(`filemetas` 与旧 `meta` 都没有)——
时长是**条目级**的 `duration`。`BaiduPanMediaInfo` 只留着兼容旧形状,⛔ 新字段不要再往里加。

### 账号信息(`uinfo`)

`uk` / `netdisk_name` / `avatar_url` / `vip_type`。

### 错误信封

`errno`(0 = 成功)/ `show_msg`(列表与播放流)/ `errmsg`(`filemetas`)
—— 两个名字都认,⛔ 别只认一个。播放流失败还可能带 `adTime` / `adToken`。

### OAuth 失败

`{"error":"invalid_grant","error_description":"..."}`。⚠️ 与 `errno` 分开:
设备码轮询时「用户还没确认」也是一个 OAuth 错误响应,要能分辨是**哪个**码。

## 5. 错误码(只列本项目会处置的)

| errno | 含义 | 处置 |
|---|---|---|
| `-6` | Token 无效/过期 | 刷新 token(`20016` / `20017` / `31045` 同义) |
| `-7` | 无权访问 / 文件名非法 | 目录不可用(多半是应用目录名不对);删除时也可能是路径非法 |
| `-9` | 不存在 | 目录/文件不可用;删除时就是要删的东西已经不在了 |
| `111` | 有其他异步任务正在执行 | 只在 `async≠0` 时出现;本项目固定 `async=0`,不该遇到 |
| `133` | 非会员要看广告 | 带 `adToken` 重试一次 |
| `31301` | 非音视频文件 | 不给播放入口 |
| `31304` | 格式不支持播放 | — |
| `31326` | 防盗链(UA 不对) | — |
| `31338` | 码率太高 | 建议下载 |
| `31339` | 非法媒体文件 | — |
| `31341` | 正在转码 | **可重试** |
| `31346` | 转码失败 | — |
| `31347` | 视频太长不支持在线播 | 只能下载 |
| `31360` | dlink 过期(8 小时) | **可重试**(重新取 dlink) |
| `31362` | 签名错误(dlink 查询串被截断) | — |

**刷新 token 的码集合**:`{-6, 20016, 20017, 31045}`。
**可原样重试一次的码集合**:`{31341, 31360}`。

## 6. `refresh_token` 的三条坑(§3.4)

1. `refresh_token` **只能用一次**,刷新后旧的立刻失效 → 新的必须落盘;
2. 刷新请求**失败会作废旧 `refresh_token`** → 失败 = 重新授权,
   ⛔ **不得**用旧的循环重试(那只会反复作废);
3. 同一应用**第二次申请 token 会让第一次失效** → 只保留一份。

推论:刷新必须**单飞**(并发调用方 await 同一个 Task),任意时刻最多一条在刷新。
实现见 `BaiduPanConnection`。

## 7. 频率限制

应用的调用配额**极低**(具体数字官方未公开,⛔ 不写未核实的数字;设计一律按
「极低」保守处理)。所以:
- 能直连就不探转码流(`method=streaming` 只在判成转码后才发);
- 列表**按需翻页**:浏览页滚到底才取下一页,⛔ 不一次把整个目录拉完;
- 不做逐字搜索、不做后台轮询。

### 7.1 `limit` 与翻页(本项目怎么用)

官方《获取文件列表》原文:`limit` 默认 `1000`,**建议**最大不超过 `1000`。
⚠️ 超限会报错还是静默截断**没有一手证据**(官方错误码表里没有对应的码),所以⛔ 不越界。

本项目按**两条路径**给 `limit`,⛔ 不要混用:

| 路径 | 一页条数 | 依据 |
|---|---|---|
| 浏览页按需翻页(`FileSourceViewModel.browsePageSize`) | 100 | 一屏十几张卡,100 条约 3–4 屏 |
| 必须一次拿整层(`BaiduPanAPIClient.list()`) | 1000 | 官方建议上限;配额按次记,一次多拿少发几次请求 |

⚠️ **浏览页⛔ 不能拿接口上限当一页大小**:每拉一页都会连带 `filemetas` 按 100 个 `fs_id`
一批串行打、对累计整套重跑 TMDB 刮削、并重算整套条目的排序与合成。
一页 1000 条 = 首屏就打 10 次 `filemetas`,而用户只看得到头几屏。

翻页用 `start` + `limit`(`start` 从 0 开始)。这是官方错误码表给出的 `list` 翻页方式
(「读取 `list`,按 `start + limit` 继续分页」)。⚠️ 与 `method=listall` **相反** ——
`listall` 必须用它回传的 `cursor`,⛔ 不能自行累加步长(见 §2.8)。

⚠️ **下一页的起点是 `start + limit`(服务端口径),⛔ 不是 `start + 本页条数`**:
`list` 的条目里可能有缺 `path` / `fs_id` 的(解码时丢掉),那种条目**服务端照样推进了页**,
用本页条数推进会漏项。

⇒ 反过来,**「已列出的条数」就是下一次的 `start`**:服务端是**先全目录排序再切片**,
列到第 N 条,下一页的起点就是 N。所以落盘缓存复原出来的游标 = 已有条数
(老版本写的缓存也是这个口径;即便目录大到被 `maxPages` 截断,截掉的也是**尾部**,
⛔ 不影响前面条目的位置)。

### 7.2 `list` 拿不到总数(所以终止判据只能是「不满页」)

`method=list` 的响应参数表里**既无 `total` 也无 `has_more` 也无 `count`** ——
那两个字段是 `method=listall` 独有的(§2.8)。⇒ 本项目:

- 「还有没有下一页」**只能靠「这一页不满 `limit`」推断**(与 OpenList 的做法一致,
  它既不用 `total` 也不用 `has_more`);
- UI **不给「共 N 项」**——百度这一侧拿不到总数,⛔ 不猜(115 才有,见 `PAN115_API.md` §3)。

⚠️ 官方另有一个《获取分类文件总个数》(`GET /api/categoryinfo`),但 `category` 是必填、
要对 7 个分类各发一次请求,且 `total` / `count` / `size` 三个字段的语义官方自己都写
「当前页面未单独说明其语义」⇒ 实际不可用于分页总数。

### 7.3 `listall` 与 `list` 的差别(本项目**不用** `listall`)

| | `method=list` | `method=listall` |
|---|---|---|
| 端点 | `pan.baidu.com/rest/2.0/xpan/file` | `pan.baidu.com/rest/2.0/xpan/multimedia` |
| `limit` | 建议 ≤ 1000 | 上限 10000 |
| 总数信号 | ❌ 无 | `has_more` + `cursor` |
| 翻页推进 | `start += limit` | ⛔ **必须**用回传的 `cursor` |
| 频控 | (同 `list`) | 有专门错误码 `31034`,官方建议 ≤ 8–10 次/分 |

⇒ 本项目用 `list`:`listall` 的递归模型与「逐层列目录」对不上,且要换端点。

### 7.4 边界与未知量

- **`limit > 1000` 的确切行为**(报错 / 截断 / 忽略):查不到一手证据。官方只说「建议」。
- **`start` 偏移在目录内容变动时是否漏项 / 重项**:查不到证据。官方只保证静态目录下的
  `start + limit`;`desc` 参数的说明「排序对象是当前目录下所有文件,不是当前分页下的文件」
  说明服务端先全目录排序再切片,理论上支持偏移,但目录翻页期间增删文件的行为查不到证据。
  ⇒ 本项目的翻页失败只提示「重试」,⛔ 不据此断言条目完整。
