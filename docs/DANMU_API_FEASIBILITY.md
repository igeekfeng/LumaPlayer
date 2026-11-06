# danmu_api 本地 Docker 部署可行性分析

> 对象:`https://github.com/huangxd-/danmu_api`(LogVar 弹幕 API 服务器)
> 目的:本地 Docker 跑起来,给 LumaPlayer 当弹幕服务,替代弹弹play 开放平台
> 文中带「实测」的条目都是在本机真跑过的,命令与输出见 §2。

## 0. 结论

**可行。** 部署与协议核对完成,LumaPlayer 已支持自建服务作为弹幕来源(接入方式见 §7)。

| 环节 | 结论 | 依据 |
|---|---|---|
| Docker 本地部署 | ✅ 可行 | 官方镜像 `logvar/danmu-api:latest` 有 arm64,本机 Docker Desktop 起容器、接口全部通 |
| 弹弹play 协议兼容 | ✅ 一致 | LumaPlayer 实际调用的 4 个端点,返回体字段与 `DANDANPLAY_API.md` 一致 |
| 接入 LumaPlayer | ✅ 已支持 | 自建服务与官方并列为弹幕来源、默认官方(§3.1),自建跳过签名头与 AppId / AppSecret(§3.2),绑定 / 缓存按来源隔离(§3.3) |

`Tools/danmu-api/` 与 LumaPlayer 多弹幕来源两侧都已实现。

---

## 1. 为什么要做这件事

门槛(`docs/DANMAKU.md` §1):官方弹弹play 要 AppId / AppSecret —— 用户得自己去
`dev.dandanplay.com` 注册开发者、创建应用、等审核。这是用官方服务唯一的门槛。

danmu_api 的价值:

- **不用注册**。自建服务,鉴权是 URL 路径里的令牌,不签名、不审核。
- **源多得多**。爱优腾芒哔咪人韩巴狐乐西埋帆红,还有本地弹幕上传。默认源顺序只开了
  `douban,360,renren,hanjutv`,手动加 `tencent,youku,iqiyi,imgo,bilibili,...` 后覆盖主流平台。
- **不受弹弹play 配额 / 限流约束**。
- **能补弹弹play 没有的**:本地 XML / ASS 弹幕上传(`/api/v2/local-danmu/upload`),
  对老番、冷门番、国产剧尤其有用。

代价在 §6。

---

## 2. 本轮实测记录

环境:macOS 27 / Apple Silicon / Docker Desktop 4.90.0 / Engine 29.7.2(linux/arm64)。

### 2.1 镜像

```
docker manifest inspect logvar/danmu-api:latest
→ amd64 + arm64 双架构,latest 更新于 2026-11-01,约 139 MB
```

arm64 原生可用,不需要 Rosetta。

### 2.2 容器

`Tools/danmu-api/docker-compose.yml` 起的容器:

```
danmu-api | Up | 127.0.0.1:9321->9321/tcp
```

资源占用(空闲):CPU 0.00%,内存 95 MB。相当轻。

### 2.3 接口逐个核对

LumaPlayer 的 `DandanplayClient` 只发 4 个请求(`DandanplayClient.swift:45-94`)。
下面每个都用 LumaPlayer 的真实请求形发过:

| 端点 | LumaPlayer 请求 | 实测结果 | 兼容性 |
|---|---|---|---|
| `POST /api/v2/match` | `{"fileName","fileHash","fileSize","videoDuration","matchMode"}` | `{"errorCode":0,"success":true,"isMatched":true,"matches":[{"episodeId","animeId","animeTitle","episodeTitle","type","typeDescription","shift",...}]}` | ✅ 字段全对,`shift` 有值 |
| `GET /api/v2/bangumi/{id}` | 无参数 | `{"errorCode":0,"success":true,"bangumi":{"animeId","animeTitle","episodes":[{"episodeId","episodeTitle","episodeNumber","url",...}]}}` | ✅ 720 集的长篇返回 224 KB,30 ms(缓存命中) |
| `GET /api/v2/search/episodes?anime=&episode=` | 同左 | `{"animes":[{"animeId","animeTitle","type","typeDescription","episodes":[{"episodeId","episodeTitle"}]}]}` | ✅ |
| `GET /api/v2/comment/{id}?withRelated=true&chConvert=1` | 同左 | `{"count":7615,"comments":[{"cid","p","m",...}]}` | ✅ |

`DandanplayCommentResponse` 解 `count` + `comments`,`DandanplayComment` 解 `cid`/`p`/`m`
(`DandanplayModels.swift:113-121`)—— danmu_api 都给。

### 2.4 `p` 字段的尾巴

dandanplay 规范的 `p` 是 `时间,模式,颜色`。danmu_api 会在末尾加来源标签:

```
"p": "0.00,1,16777215,[youku]"
```

LumaPlayer 的解析是 `DanmakuComment.swift:31-35`:

```swift
let fields = p.split(separator: ",", omittingEmptySubsequences: false)
guard fields.count >= 3, ... else { return nil }
// 只读 fields[0..2]
```

`count >= 3` 是下限不是上限,尾巴被忽略。**不用改解析**。✅

顺带一个观察:dandanplay 的 `m` 是纯文本,danmu_api 会给重复弹幕加 ` x N`、给有赞的加
点赞数尾巴(`"周末签到~ x 19"`、`"喜欢的东西是拉面…🔥1.8k"`)。LumaPlayer 原样当弹幕文本渲染,
会显示出来。纯外观差异,不影响功能。

### 2.5 鉴权:签名头被忽略

LumaPlayer 每个请求都带 `X-AppId` / `X-Timestamp` / `X-Signature`
(`DandanplayClient.swift:135-139`)。

dandanplay 官方服务要校验这套签名。**dandanplay 的这套签名 danmu_api 完全不校验** ——
worker 里只看 URL 第一段是不是令牌(`danmu_api/worker.js:109-136`)。实测:

```
伪造 X-AppId: x  X-Timestamp: 1  X-Signature: y  →  HTTP 200
```

所以签名头可以照发,服务端不看。**但反过来说:`DandanplayClient.swift:127` 的
`guard !appID.isEmpty, !secret.isEmpty` 会先拦下来**,用户必须填两个假值才能通过。
接入改造时这点要处理(§3.2)。

### 2.6 令牌位置

dandanplay 的鉴权是请求头,dandanplay 的令牌是 URL 路径前缀 `/{TOKEN}/api/v2/...`。
**dandanplay 不支持 `?token=` 查询参数**(`worker.js` 里只有路径解析)。

所以接进去之后,设置页要填的地址是 `http://127.0.0.1:9321/<TOKEN>`,不是
`http://127.0.0.1:9321`。这一点直接决定了 §3 的改造形状。

### 2.7 延迟

| 场景 | 实测 |
|---|---|
| `match` 冷(首次,含 Bangumi Data 预热) | 4.7 s |
| `match` 热(缓存命中) | 10 ms |
| `comment` 冷(首次拉上游) | 1.07 s |
| `comment` 热(dandanplay 侧缓存) | 15 ms |

LumaPlayer 侧另有 `DanmakuCommentCache`(4 小时),所以一集只拉一次。
冷启动 1 秒左右可接受,播放页有加载态。

### 2.8 源站连通性

本机直连(未走代理)实测:

```
www.iqiyi.com     HTTP 200  0.30 s
v.qq.com          HTTP 200  0.38 s
v.youku.com       HTTP 200  0.38 s
```

国内主流平台直连可用。**巴哈姆特(bahamut)直连不通**,要 `PROXY_URL=bahamut@...` 反代,
本部署没开。

---

## 3. LumaPlayer 侧接入设计

### 3.1 多来源并列,默认官方

自建服务不替换官方,而是作为另一个弹幕来源(`DanmakuSource`)与官方并列:设置 › 弹幕里添加任意个
自建服务(名称 + 带令牌的地址),选一个默认来源(缺省官方);播放页「弹幕」面板可以为本集临时换来源。
来源配置(`DanmakuSourceSettings`)放凭据文件,不放 UserDefaults:令牌写在地址路径里。

`DandanplayBase`:scheme + host + port + 路径前缀,如 `http://127.0.0.1:9321/87654321`。空串、非 http/https、
缺 host、带 query / fragment 一律 `nil`,客户端如实报错**不静默回退官方**(回退只会换来一串看不懂的 403)。
80 / 443 不落进 URL。签名只覆盖 path、不含域名(`DANDANPLAY_API.md` §1),所以 `signaturePath` 不受地址影响。

### 3.2 鉴权:按来源分

`DandanplayClient` 每次请求带 `DandanplayServer`:

- `.official(DandanplayCredentials)` → 签名头,AppId / AppSecret 缺一不可;
- `.custom(baseURL:)` → 不发签名头(danmu_api 忽略它们,§2.5),也不要 AppId / AppSecret。

### 3.3 ID 按来源隔离

danmu_api 的 `episodeId` / `animeId` 是它自己的编号,与官方弹弹play 的同号不同片;对不认识的 ID,
`/comment` 与 `/bangumi` 回 HTTP 404。所以绑定、弹幕缓存、剧集列表记忆都按来源 id 分开(`DANMAKU.md` §3),
⛔ 不能拿官方记住的 ID 去问自建服务。danmu_api 的 ID 映射在进程内,重启 / 无服务器部署换实例后旧 ID 也会 404:
`DanmakuService.resolve` 把绑定 ID 的 404 当绑定失效,删掉后重新匹配。

### 3.4 一个必须同步改的文档

`docs/DANMAKU.md` §1(弹幕来源与凭据口径)与 `docs/DANDANPLAY_API.md` §1(主机声明、
签名与凭据来源)必须和实现一致:默认官方 `api.dandanplay.net`,地址可改自建兼容服务;
自建服务不校验签名。按 `CLAUDE.md` 硬规则 1 的口径,文档先于 / 同步于代码。

---

## 4. 已落地的部署

`Tools/danmu-api/`:

```
docker-compose.yml      服务定义,挂 config/ 与 .cache/
env.example             配置模板(只列用到的,改完热重载)
config/.env             运行时配置,从 env.example 复制,不入库
.cache/                 运行时缓存,不入库
```

首次启动前 `cp env.example config/.env`(根 `.gitignore` 的 `.*` 规则排除所有 dotfile,
所以模板不能叫 `.env.example`)。之后改 `.env` 热重载生效。

日常操作:

```bash
cd Tools/danmu-api
cp env.example config/.env   # 首次
docker compose up -d         # 启动
docker compose logs -f       # 看日志
docker compose down         # 停止
```

管理界面:`http://127.0.0.1:9321/`(UI 后台,日志 / 请求记录 / 本地弹幕上传)。

两个配置决定值得单独说:

- **`RATE_LIMIT_MAX_REQUESTS=0`**。默认 3 次/分钟/IP,而 LumaPlayer 匹配一集要走
  `match → bangumi → comment` 三步,连看几集就撞限流。自建服务没有上游滥用压力,关掉。
- **`SOURCE_ORDER` 扩到 16 个源**。默认只开 4 个,不加 `tencent,youku,iqiyi,...`
  等于大部分平台不参与匹配。代价是冷匹配从 ~1 s 涨到 ~5 s。

---

## 5. 不推荐的方案

| 方案 | 为什么不推荐 |
|---|---|
| 本地 MITM 代理 + `/etc/hosts` 把 `api.dandanplay.net` 指到 127.0.0.1 | 需要往系统钥匙串装自签 CA、改 `/etc/hosts`、HTTPS 证书域名匹配。Docker 重启、CA 到期都得重新弄,而且 ATS 对非本地域名要求 HTTPS。脆。 |
| `URLSessionDelegate` 里改写请求 URL | 技术上能work(ATS 看的是改写后的 127.0.0.1),但等于在传输层藏一个重定向,以后排查问题会很痛苦,也解释不清「为什么请求域名和配置的不一样」。 |
| 直接把 danmu_api 暴露到局域网给电视 / FengMi 用 | danmu_api 本身支持 FengMi 短地址(`/danmaku`),但它没有用户体系,令牌就是路径前缀。**局域网暴露 = 任何人拿到令牌就能用你的服务抓弹幕**。要用就一定要改令牌、加防火墙。 |

---

## 6. 风险与取舍

### 6.1 匹配质量 —— 最需要留意的一条

`/match` 的 `isMatched: true` 在 danmu_api 上**不等于「匹配对了」**。实测一例:

```
fileName = "火影忍者 S01E05"
→ isMatched: true,命中《火影忍者 疾风传(2007)》第 5 话
   而不是《火影忍者(2002)》第 5 话
```

另一个例子:`fileName = "遮天"` → `isMatched: true`,命中《手遮天(2026)》。

LumaPlayer 的处理是 `DANMAKU.md` §3 步骤 4:`isMatched` → 直接采用并写绑定。
**这意味着一次错配会被记住 4 小时(`DanmakuCommentCache`)并绑进集 / 剧绑定**,
后面同一集都走缓存。

官方弹弹play 对同样输入的行为没有一手证据,所以不能说这是 danmu_api 独有的问题。
但自建服务换了匹配引擎,**匹配手感一定会变**,上线初期建议:

- 开 `USE_BANGUMI_DATA=true`(已开),元数据全了匹配才准;
- 「解除这一部的匹配」按钮会用得上(删集绑定 + 剧绑定);
- 或者先关掉设置里的「播放时自动加载弹幕」,手动确认每部。

### 6.2 上游平台反爬

danmu_api 是抓爱优腾芒哔咪等平台的弹幕。这些平台的接口随时可能变、可能风控。
dandanplay 官方也依赖同样的上游,但 danmu_api 更新更频繁(镜像 latest 2026-11-01 还在推)。
**需要定期 `docker compose pull && docker compose up -d`**,或者上 watchtower 自动更新。

### 6.3 冷匹配慢

16 个源的冷匹配 ~5 s。dandanplay 侧缓存 3 分钟 / 5 分钟,LumaPlayer 侧 4 小时。
第一次点开一部剧会等一下。能接受,但别指望和官方服务一样快。

### 6.4 巴哈姆特 / 港澳台番剧

本机直连不通,要 `PROXY_URL=bahamut@https://<反代>`。没配之前,港澳台番剧的弹幕拿不到。

### 6.5 授权与合规

仓库 `LICENSE` 是 **AGPL-3.0**(`package.json` 里写的 `ISC` 与它冲突,以 LICENSE 文件为准)。
自己用、不改、不分发,没问题。**改了代码并对外提供服务,AGPL 的网络条款会生效** ——
本部署不改 danmu_api 源码,不受影响。

另外 danmu_api 抓取第三方平台弹幕这件事本身处于各平台 ToS 的灰色地带,
项目 README 也写了「请不要在国内媒体平台宣传本项目」。自己用没问题,别推广。

---

## 7. 本地服务的接入方式

地址可配:`DandanplayBase`、多来源(`DanmakuSource`,默认官方)、按来源隔离的绑定 / 缓存、失效绑定重新匹配,
见 `docs/DANMAKU.md` §1 / §3 与 `docs/DANDANPLAY_API.md` §1。

`cd Tools/danmu-api && docker compose up -d` → 设置 › 弹幕填
`http://127.0.0.1:9321/<TOKEN>`(`config/.env` 里的 `TOKEN`,当前是 `87654321`)
→ 播一集,看 `docker compose logs -f` 里的实际请求。判据:`match` 拿到 `isMatched`,
`comment` 返回的 `count` 与播放画面上的弹幕条数对得上。
