# 弹幕架构

> 接口事实在 `DANDANPLAY_API.md`;本文件讲**分层、数据流与取舍**。
> 章节编号稳定,代码注释按「DANMAKU.md §n」引用。

## 1. 目标与边界

- 播放时叠加弹幕:Emby 与百度网盘两路来源都有,来源无关。
- 弹幕来自**弹弹play 开放平台**;本项目没有服务器 → **AppId / AppSecret 用户自填**(设置 › 弹幕)。
- 只读:不发送弹幕、不登录弹弹play 账号、不碰任何服务端写接口。
- 非目标:B 站等其它弹幕源(留了提供方无关的模型,但不预先写抽象协议)、高级弹幕 / 代码弹幕、
  弹幕屏蔽词。

## 2. 分层

```
设置 › 弹幕(DanmakuSettingsView)
   ├─ AppId / AppSecret ──→ CredentialStore(凭据文件)
   └─ 外观偏好 ─────────→ DanmakuSettingsStore(UserDefaults,全 App 一份)

播放页(每集一个 PlayerViewModel)
   PlayerViewModel.danmaku : DanmakuController   @MainActor @Observable,每集一份
        │  query = DanmakuMediaQuery.make(for: PlaybackSource)   ← 来源差异只在这里
        ▼
   AppContainer.danmaku : DanmakuService          actor,全 App 一份
        ├─ DanmakuBindingStore   actor  集 / 剧 → 弹幕库 的本地绑定(Application Support)
        ├─ DanmakuCommentCache   actor  episodeId → 已解析弹幕(Caches,4 小时)
        └─ DandanplayClient      Sendable struct  签名 + 传输 + 解码(无状态)
        ▼
   LoadedDanmaku([DanmakuComment] 按时间升序)
        ▼
   DanmakuController.placement(for:) ─→ DanmakuLayout(纯函数排版,参数不变即复用)
        ▼
   DanmakuOverlayView(CALayer + displayLink,视频之上、控件之下、不吃点击)
        ↑ 时间:DanmakuClock 在 5 Hz 的 positionSeconds 之间按倍速外推
```

| 类型 | 位置 | 隔离 |
|---|---|---|
| `DandanplayEndpoint` / `DandanplayClient` / DTO / `DandanplayError` | `Core/Danmaku/Dandanplay/` | 值类型,`Sendable` |
| `DanmakuComment`、`DanmakuMediaQuery`、`DanmakuLayout` | `Core/Danmaku/` | 值类型 / 纯函数 |
| `DanmakuService`、`DanmakuBindingStore`、`DanmakuCommentCache` | `Core/Danmaku/` | `actor` |
| `DanmakuSettingsStore` | `Core/Danmaku/` | `@MainActor @Observable`(同 `SubtitleStyleStore`) |
| `DanmakuController` | `Features/Player/Danmaku/` | `@MainActor @Observable` |
| `DanmakuOverlayView`、`PlayerDanmakuMenu`、`DanmakuPickerSheet` | `Features/Player/Danmaku/` | View |

**提供方无关的边界**是 `DanmakuComment`(时间 / 模式 / 颜色 / 文本)与 `DanmakuCandidate`。
排版与渲染只认它们;将来加别的提供方,写一个「DTO → `DanmakuComment`」转换和一个 Service 分支即可。
⛔ 现在不为「可能的第二个提供方」预先抽协议。

## 3. 匹配流程(`DanmakuService.resolve`)

每一层都只在上一层没结果时才发请求:

1. **凭据**:没填 → `DandanplayError.credentialsMissing`,⛔ 不发任何请求。
2. **集绑定**(`itemKey`):这一集手选过 / 精确匹配过 → 直接加载。
3. **剧绑定**(`seriesKey` + 集号):这一部剧绑定过作品 → `GET /bangumi/{animeId}`(进程内记忆),
   按 `episodeNumber` 找**唯一**相等的一集 → 写集绑定并加载。对不上就落到第 4 步。
4. **`POST /match`**:有真实指纹就带 `hashAndFileName`(见 3.1),否则 `fileNameOnly` + 32 位占位串。
   `isMatched` → 采用并写集 + 剧绑定。
5. **TMDB 降级层**:有 `ProviderIds.Tmdb` → `GET /search/episodes?tmdbId=&tmdbIdType=&episode=`,
   按集号挑唯一命中。先按目标类型查(剧集 `tmdbIdType=0` / 电影 `1`),查不到再试另一套。
6. **唯一候选采用**(`DanmakuCandidateMatcher`):第 4 步的模糊候选里,若**恰好一集**通过
   全部硬门槛(集号 / 季 / 类型)与标题软校验,自动采用。
7. 都不成立 → `needsSelection(candidates)`,菜单提示「请选择」,⛔ 不自动取第一个模糊结果。
8. 用户在 `DanmakuPickerSheet` 里从候选或关键词搜索结果中选一个 → `select` → 写集 + 剧绑定 → 加载。

**为什么第 6 步不用加权打分**:打分要调阈值,偏低就会把「第二季第 5 话」判给「第一季第 5 话」。
唯一性判据没有阈值,剩 0 个或 ≥2 个都交回用户。

**集号 token**(`DanmakuEpisodeToken`):`episodeTitle` 是模糊候选里唯一带集数语义的字段,
形状很杂(`第5话 …` / `05` / `EP06` / `第十二话` / `S2 …` / `C1 …`)。只认这几种形态,
认不出返回 nil —— ⛔ 不做「标题里出现过这个数字就算」的宽松兜底(`S5 聖地巡礼` 里的 5 不是第 5 话)。

**加载**:先查 `DanmakuCommentCache`(4 小时内有效),否则 `GET /comment/{id}?withRelated=true&chConvert=1`,
解析(丢弃无法解析的并计数)→ 排序 → 写缓存。过期的缓存文件启动时删掉(`DanmakuCommentCache.cleanUp`)。

**身份键**(`DanmakuMediaQuery`):

| 来源 | `itemKey` | `seriesKey` | `/match` 文件名 | TMDB ID |
|---|---|---|---|---|
| Emby | `emby\|{serverId}\|{itemId}` | 有 `SeriesId` 与 `IndexNumber` 时 `emby\|{serverId}\|series:{SeriesId}` | 剧集:`剧名 S{季}E{集}`(合成,Q45);电影:`Name` | `ProviderIds.Tmdb` |
| 百度 | `baidu\|fsid:{fs_id}` | 文件名解析出集号时 `baidu\|dir:{父目录}` | 真实文件名去扩展名 | 文件名里的 `{tmdbid-…}` |

按服务器隔离沿用「每台服务器完全隔离」。删 Emby 服务器时按 `emby|{serverId}|` 前缀删掉它的集 / 剧绑定(`AppContainer.removeSource`)。

「解除这一部的匹配」(选择面板底部):删集绑定 + 剧绑定,回到等用户挑的状态。

### 3.1 媒体指纹(`DanmakuFingerprint`)

`/match` 的 `fileHash` 是「同一份文件」唯一的硬证据。`DanmakuFingerprint` 算文件前 16 MiB 的 MD5,
但**只服务 Emby 直连流**:

- 转码流的前 16 MiB 是编码器输出,与源文件不是同一份字节,算出来没有意义 → 不试;
- 走 `Range: bytes=0-16777215`,并严格校验 `Content-Range`(206 + `start == 0` + 总长自洽);
- 服务端忽略 Range 回 200 时,**只有**整文件 ≤ 16 MiB 才接受 —— ⛔ 绝不为算指纹把整部电影下下来;
- 任何一步不满足就返回 nil,退回文件名匹配。指纹是锦上添花,⛔ 不抛错、不挡播放。

代价与开关:起播时多一次 16 MiB 读取。对 Emby 直连流来说这正是播放器接下来要读的字节
(服务端 / 内核 HTTP 缓存都可能已有),所以**默认开**;设置 › 弹幕 的「用文件指纹提高匹配准确度」
可以关掉(限速 / 按流量计费的服务器),关掉后退回文件名匹配。

百度来源**不算指纹**:`dlink` 下载要额外消耗网盘流量,而它的真实文件名已经足够(见 §6)。

## 4. 渲染

- **为什么不交给 mpv**:mpv 只能把弹幕当 ASS 字幕轨画,改字号 / 透明度 / 区域 / 偏移都要重新生成并重载,
  还会占掉用户正在用的字幕轨。自己画一层则所有外观即时生效。
- **渲染**:每条弹幕出场时预渲染一次位图(`DanmakuSprite`:文字 + 描边),放进一个 `CALayer`;
  之后每帧只改图层位置,由 Core Animation 在 GPU 上合成。⛔ 不用 `TimelineView` + `Canvas`:每帧在主线程重画整窗口,
  120 Hz 屏上 30–40 条在场只剩约 40 帧。
- **层级**:`PlayerWindowView` 里 `MPVView` 之上、`interactionLayer` 之下,`allowsHitTesting(false)`。
  错误页出现时弹幕层仍在(在错误覆盖层下面,被盖住)。
- **时间**:`positionSeconds` 只有 5 Hz。`DanmakuClock` 以最近一次位置为锚点按倍速外推;
  新位置误差 < 0.5 秒时锚点取当前外推值(位置不跳),误差在 1 秒内靠微调速度(≤ ±10%)匀速吸收,
  更大视为 seek 直接对齐;暂停 / 缓冲时停住,displayLink 同时暂停。
  逐帧位置按 displayLink 的 `targetTimestamp`(这一帧上屏的时刻)算,并对齐到屏幕像素。
  诊断(`DanmakuFrameDiagnostics`)只在明确暂停 / 恢复 / displayLink 拆建与窗口可见性变化时断开帧比较;
  连续运行中 ≥ 250ms 的间隔计为长停顿,⛔ 不按间隔大小猜成暂停。
- **偏移**:画面时间 − (`/match` 的 `shift` + 用户手调),正数 = 弹幕延后。手调只在本集有效(0.5 秒步进)。
- **排版**(`DanmakuLayout`,纯函数):
  - 滚动弹幕**同速**(`画面宽 / 滚动时长`),所以不会后追前;一行能放下新弹幕的条件只有「上一条尾巴已离开右缘 + 1.5 字宽」。
  - 顶部 / 底部居中静止 4 秒,各自一套行,与滚动行可重叠。
  - 所有行都占着时**丢弃**这一条(密度控制),⛔ 不叠。
  - 行数 = 画面高 × 显示区域 / (字号 × 1.3)。
  - 文字宽度在加载时于后台用 CoreText 测一次(100pt 下测、存「每 pt 宽度」),字号 / 窗口变化只需等比缩放重排,不再测量。
  - 排版结果按 `Parameters`(画面尺寸取整、字号取整、外观开关)记忆,拖窗口时才重排。
- **取可见**:按 `start` 二分 + 回看最长在场时长,每帧只碰在场附近的几十条。
- **外观**:系统粗体 + 实心描边(深色字白边、其余黑边;模糊阴影在移动中会糊);整层不透明度;
  字号以 1080 高为基准随窗口缩放(最小 12pt)。

## 5. 交互入口

| 入口 | 位置 |
|---|---|
| 控制栏「弹幕」菜单 | 字幕菜单右侧:显示开关、状态(条数 / 匹配情况 / 错误)、重试、选择弹幕…、偏移 ±0.5 秒、设置入口 |
| 快捷键 D | 显示 / 隐藏(`PlayerCommands` 表 + `PlayerWindowView.onKeyPress`) |
| 选择弹幕面板 | 播放窗口 sheet;打开期间钉住控制栏 |
| 设置 › 弹幕 | AppId / AppSecret;自动加载、文件指纹、不透明度、字号、滚动时长、显示区域、三种类型开关 |

「显示弹幕」是本集的会话开关,初值取设置里的「播放时自动加载弹幕」;关着时不发任何请求,打开时才加载。
转码 seek / 重试会重走 `PlayerViewModel.start()`,但弹幕只在第一次加载(`startIfNeeded` 判重)。

## 6. 取舍与后续

- **文件 Hash:Emby 算,百度不算**。`/match` 的 `fileHash` 要文件前 16 MB 的 MD5。Emby 直连流本来就要从头读,
  这 16 MiB 正是播放器接下来要读的字节 → 算(见 §3.1,可在设置里关)。百度 `dlink` 要额外消耗网盘流量 →
  不算,填 32 个 `0` 占位。服务端**硬性要求** `fileHash` 是 32 位串(少了直接 `errorCode 2`,
  见 `DANDANPLAY_API.md` §2),占位串查不到 Hash 记录就按文件名匹配,正是要走的路径。
- **Emby 拿不到文件名**:`MediaSource.Path` 按契约不用,只能合成名字(Q45)。手选一次后同剧其它集走剧绑定。
  TMDB 降级层(§3 第 5 步)是这条短板的第二重保险。
- **弹幕数量**:不做「最多显示 N 条」的截断,密度由行数自然控制。
- **屏蔽词 / 合并重复**:未做。
