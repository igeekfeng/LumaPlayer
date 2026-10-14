# 播放来源抽象改造方案

> 状态:**P1–P6 全部落地(全量 614 项测试全绿、0 warning)**。
> 本文件是这次改造的唯一计划来源。
> 阶段落地会改动本文的「状态」段与 §9 的勾选,其余章节原则上不再改结构。
>
> ⚠️ 两处**与本方案原设计的偏差**(记录在案):
>
> 1. **`SourceProvider` 协议晚了一拍**:原 §4.2 打算 P3 就立它(列库 / 列条目 /
>    取图片 / 读进度)。P3 落地时发现上层真正需要抽象的是**播放**那一层
>    (会话准备 + 进度出口),而「列库 / 列条目」目前只有百度一个消费者 ——
>    为一个消费者立协议是过度设计。所以 P3 只抽了 `PlaybackSessionPreparing`
>    与 `PlaybackReporting`;`SourceProvider` 随 P4(统一条目 `SourceItem`)
>    一起落地(现在它有百度 + Emby 两个实现:后者只做 `SourceItem` 映射)。
>
> 2. **P6 的形态改了**:原 §5 P6 写「首页「继续观看」聚合两类来源 +
>    `BrowseRoute` 携带 `SourceItemRef`」。实际落成**百度来源页顶部的
>    「继续观看」区**(决策见 §6.7),`BrowseRoute` **未改** —— 那个「跨来源
>    统一首页」的形状不在本次范围内(理由同 §6.4:不为了一个来源去重构共享导航)。

## 0. 背景与目标

`exp/avkit-rust-core` 分支的 `096cf5f`(feat: 对接百度网盘)已经跑通了百度网盘的**对接**,
但它的**形式**是「Emby 之外的另一个入口」:一个独立的 `BaiduPanSourceView` sheet,
挂在 `AddServerView` 底部一个「改用百度网盘…」按钮上,与 `BrowseView` 的导航栈完全平行。

本次改造要的是相反的分层:**「播放来源」本身是一层**。Emby 与百度网盘是这一层的两个实现,
将来还会有第三个(其它网盘、本地目录、WebDAV…)。用户在**添加的那一刻**选来源类型。

同时要解决一个体验落差:百度网盘**不提供**封面、简介、年份、剧集结构、服务端进度这些
Emby 有的东西,但用户期望选中百度网盘时也能有**接近 Emby 的观感**(海报卡片、详情页、
继续观看)。这必须在 App 侧补一层能力,不能靠「百度给什么就显示什么」。

### 目标

1. 添加流程第一屏 = 选来源类型(Emby / 百度网盘 / …),而不是 Emby 表单 + 一个侧门按钮。
2. Emby 与百度在一个列表里平等共存:可切换、可删除、可标记最近使用。
3. 百度源在 UI 上呈现为「海报 + 标题 + 详情」,缺数据时**优雅降级**(图标卡),⛔ 不伪造字段。
4. 新增第三个来源时,只新增「来源实现」+「一个枚举 case」,不改共享内核。

### 非目标(本次不做)

- ⛔ 改播放内核(main 仍是 libmpv;exp 的 Rust/AVKit 核心不搬)。
- ⛔ 把 Emby 的 `ServerProfile` 类型改名(见 §6.2 的理由)。
- ⛔ 在线刮削(TMDB 等)—— 元数据只来自用户自己的网盘(文件名 / `.nfo` / 同目录图片)。
  **2026-10-12 改**:在线刮削**要做**,形态是**客户端直连 TMDB**(⛔ 不要后端服务),
  token 由用户在设置里输入。链路本身(客户端 + DTO + token 入口 + 测试)先落地,随后**已接入**
  `BaiduPanSourceProvider`(`BaiduPanMetadataScraper`,列目录后第二趟;见 §6.3)。
  真实网络行为待验,见 `docs/KNOWN_ISSUES.md`「TMDB 在线刮削」。事实来源 `docs/TMDB_API.md`。
- ⛔ 百度网盘的写操作(上传 / 删除 / 重命名)。

## 1. 结论:需要哪些「功能增强」

一句话:**不是加一个页面,是加一层来源抽象 + 一层本地元数据合成。** 具体 6 项:

| # | 增强项 | 解决的落差 |
|---|---|---|
| E1 | **来源身份层** `SourceProfile` | 「添加时选来源」「多来源并列」 |
| E2 | **来源能力契约** `SourceProvider` | 让上层(首页/库/搜索/详情/播放)不写 `if isEmby` |
| E3 | **本地元数据合成** `SourceItem` + 解析器 | 百度缺的封面/标题/年份/简介 → 从网盘文件合成 |
| E4 | **图片通路泛化** `ImageDescriptor` | `PosterImage` 现在只认 Emby 认证头 |
| E5 | **本地续播层** `WatchProgressStore` | 百度没有服务端进度 → 撑起「继续观看」与续播 |
| E6 | **播放请求去 Emby 化** `PlaybackSource` | `PlaybackRequest(server:item:)` 表达不了百度 |

E3 是「百度也有 Emby 体验」的**真正关键**:没有它,百度源只能是一列文件名。

## 2. main 现状的耦合点(改造面实测)

> 统计于 2026-10-11:`ServerProfile` 出现在 **39** 个文件;`ServerRegistry` 出现在 **16** 个文件
> (含 10 个测试文件直接 `ServerRegistry(defaults:credentials:)` 构造)。

| 层 | 硬绑 Emby 的东西 | 影响 |
|---|---|---|
| 模型 | `ServerProfile`(只有 `baseURL`/`apiPathPrefix`/`serverID`/`userID`) | 无法表达百度来源 |
| 存储 | `ServerRegistry`(actor,存 `[ServerProfile]`,key `ServerRegistry.profiles.v1`) | 列表只装 Emby |
| 凭据 | `CredentialStore`(token/password/deviceId,全按 `serverID`) | 百度 token/AppKey 无处存 |
| 连接 | `ServerConnection`(actor,Emby 全部端点) | 百度需要自己的连接类型 |
| 播放 | `PlaybackRequest(server:item:)`、`PlaybackSession{plan, mediaSource: EmbyMediaSource}` | 表达不了「一条网盘文件」 |
| 决策 | `PlaybackDecisionEngine`(纯函数,输入 `EmbyPlaybackInfoResponse`) | 百度要**复用**它(映射输入),⛔ 不另立判断 |
| 图片 | `ImageSpec{serverID,itemID,type,tag,maxWidth}` + `PosterImageLoader`(Emby 认证头) | 百度图取不到 |
| 导航 | `BrowseRoute{library(EmbyView), search, detail(DetailItem)}` | 路由携带 Emby 类型 |
| 状态 | `AppState.currentServer: ServerProfile?` | 全局只有「当前 Emby 服务器」 |
| 进度 | 全靠服务端 `UserData`;**main 没有本地进度库** | 百度无进度可显示 |

## 3. 目标分层

```
        ┌──────────────────────────────────────────────┐
        │  添加来源 → SourceProfile(.emby | .baiduPan | …) │
        └──────────────────────────────────────────────┘
                             │
        ┌────────────────────┴────────────────────┐
        │     来源能力契约 SourceProvider          │
        │  列库 / 列条目 / 取会话 / 取图片 / 读进度   │
        └───────┬────────────────────────┬─────────┘
        ┌───────┴────────┐      ┌────────┴─────────┐
        │ EmbyProvider   │      │ BaiduPanProvider │
        │ (ServerConnection)│    │(BaiduPanConnection)│
        │ 元数据来自服务端 │      │ 元数据本地合成     │
        └───────┬────────┘      └────────┬─────────┘
                └──────────┬─────────────┘
        ┌──────────────────┴──────────────────────┐
        │  共享内核:PlaybackDecisionEngine /        │
        │  PosterImageStore / WatchProgressStore    │
        └──────────────────────────────────────────┘
```

## 4. 类型设计(签名级)

### 4.1 来源身份(新增 `Models/SourceProfile.swift`)

```swift
/// 一个播放来源的身份与**非敏感**配置。整条持久化进 SourceRegistry。
enum SourceProfile: Codable, Sendable, Equatable, Hashable, Identifiable {
    case emby(ServerProfile)          // 复用既有类型,⛔ 不改名(§6.2)
    case baiduPan(BaiduPanSource)

    var id: UUID { … }                 // 取内层 id
    var displayName: String { … }
    var lastUsedAt: Date? { … }
    /// 枚举是值类型:改 lastUsedAt 返回副本(注册表独占该字段,与旧约定一致)
    func settingLastUsedAt(_ date: Date?) -> SourceProfile { … }
}

/// 百度网盘来源。AppKey/SecretKey/token 进凭据文件,⛔ 不在这里。
struct BaiduPanSource: Codable, Sendable, Equatable, Hashable {
    let id: UUID
    var displayName: String
    /// 应用目录名(开放平台控制台里的「应用名称」);第三方只能访问 /apps/{它}(§2.1)
    var folderName: String
}
```

### 4.2 来源能力契约(新增 `Core/Sources/SourceProvider.swift`)

用 **protocol + 两种实现**,而不是 `switch`——能力会长(将来加 WebDAV/本地目录),
`switch` 会蔓延到每个调用点。身份用枚举、能力用协议,是这套设计的分工。

```swift
/// 一个来源能提供的**内容**能力。播放取会话单独走 §4.4。
protocol SourceProvider: Actor {
    var id: UUID { get }
    /// 库入口(Emby=Views;百度=应用目录/片库根)
    func libraries() async throws -> [SourceLibrary]
    /// 列一个库/目录下的条目
    func items(in library: SourceLibraryRef) async throws -> [SourceItem]
    /// 这一项要不要/能不能取封面
    func imageDescriptor(for item: SourceItem) async throws -> ImageDescriptor?
}
```

### 4.3 统一条目(新增 `Models/SourceItem.swift`)

播放层与视图层只认它,不再直接认 `EmbyItem`。

```swift
/// 来源无关的媒体条目。**所有字段可选**,缺就降级,⛔ 不填假值(沿用 EmbyItem 的立场)。
struct SourceItem: Sendable, Equatable, Hashable, Identifiable {
    let ref: SourceItemRef        // 源 id + 源内 id(Emby=ItemId;百度=fs_id)
    let title: String             // 必有:Emby=Name;百度=文件名(去扩展名)
    let kind: SourceItemKind      // .movie/.episode/.video/.audio/.folder/.unknown
    let overview: String?
    let year: Int?
    let durationSeconds: Double?
    let poster: ImageDescriptor?  // 见 §4.5
    let folderRef: SourceLibraryRef?   // 目录可进入
    /// 元数据来源,用于诊断与「这个字段可不可信」的取舍
    let metadataOrigin: MetadataOrigin // .server / .sidecarNFO / .filename / .none
}

/// `SourceItemRef` 是路由与图片缓存 key 的载体:源 id + 源内 id。
struct SourceItemRef: Sendable, Equatable, Hashable, Codable {
    let sourceID: UUID
    let itemID: String
}
```

百度侧把 `BaiduPanFile` → `SourceItem` 的映射放在 `BaiduPanMetadataSynthesizer`(纯函数):
- 标题:剥掉扩展名与常见后缀(`.2021.1080p.WEB-DL…`)→ 标题 + 年份;
- 简介/年份:优先同名 `.nfo`(Emby/Kodi 风格),没有就只留文件名解析结果;
- 封面:同目录 `poster.jpg` / `folder.jpg` / `<同名>.jpg`。

### 4.4 播放请求去 Emby 化(改 `Models/PlaybackSession.swift`、`PlaybackRequest`)

```swift
enum PlaybackSource: Sendable, Equatable {
    case emby(server: ServerProfile, item: EmbyItem)
    case baiduPan(file: BaiduPanFile)
    var contentID: String { … }
}
struct PlaybackRequest { let source: PlaybackSource; … }
```

保留 `init(server:item:)` 便利构造,4 个既有 Emby 调用点零改动。
百度侧**复用** `PlaybackDecisionEngine`:把 `BaiduPanFile` + `dlink` + `streaming` 地址
合成为一份 `EmbyPlaybackInfoResponse`,过同一个决策器(与 exp 的做法一致,但输出接 main 的
`PlaybackPlan`,不接 Rust FFI)。

⚠️ **只借判定,不借地址规则**(2026-10-11 实测):`PlaybackURLBuilder` 会走
`URLComponents.queryItems` 过滤 `api_key`,而那一趟往返把 `%2B` 重编码成 `+`
—— 百度 `dlink` 的 `sign` 一变就是 `31362 签名错误`。所以:
`decision(for:)`(判定)共用,地址由百度**原样**给出(见 §6.5)。

会话上另加 `seekStrategy`(见 §6.5):`PlaybackSession` 承载「能不能拖」,
播放层据此分派而非按 `plan.method` 反推。

### 4.5 图片通路泛化(改 `Core/Images/ImageSpec.swift`)

```swift
/// 图片从哪来。PosterImage 只认这个,不再直接拼 Emby 端点。
struct ImageDescriptor: Sendable, Equatable, Hashable {
    enum Origin: Sendable, Equatable, Hashable {
        /// Emby 图片端点(要带认证头)—— 原 ImageSpec 的语义
        case emby(ImageSpec)
        /// 百度 dlink / 缩略图(URL 自带 access_token,⛔ 不需要认证头)
        case remote(url: URL)
        /// 本地已缓存的文件(将来:下载到沙盒的 sidecar 图)
        case localFile(URL)
    }
    let origin: Origin
    let cacheKey: String   // 含 sourceID,与旧 key 规则一致
}
```

`PosterImageStore` 增加按 `ImageDescriptor` 取图的入口,内部对三种 origin 分派;
`PosterImage` 视图签名不变(仍收 `ImageSpec?`),新增一个收 `ImageDescriptor?` 的重载。

### 4.6 本地续播(新增 `Core/Playback/WatchProgressStore.swift`)

搬 exp 的 `WatchProgressStore` + `LocalResumeReporting`:按 `SourceItemRef` 存「已看秒数」,
`PlaybackProgressReporter` 对**非 Emby 来源**改为写本地库(Emby 仍上报服务端)。
首页「继续观看」行对非 Emby 来源改读本地库。

## 5. 阶段划分

每阶段独立可构建、可测;`xcodebuild test` 必须绿。

### P1 — 存储与身份抽象(Emby 行为零变化)

- 新增 `Models/SourceProfile.swift`、`Core/Sources/SourceRegistry.swift`。
- `ServerRegistry` 改为 `typealias ServerRegistry = SourceRegistry`,**保留全部 Emby 侧 API**
  (`init(defaults:credentials:)`、`all()->[ServerProfile]`、`add/update/remove/mostRecentlyUsed/markUsed`),
  使 10 个测试文件与既有代码零改动。
- 存储 key 升为 `SourceRegistry.profiles.v1`;**读时迁移**旧 key `ServerRegistry.profiles.v1`
  (`[ServerProfile]` → 包成 `.emby(_)`),⛔ 不静默丢服务器。
- 新增通用入口:`allSources()` / `mostRecentlyUsedSource()` / `add(_:SourceProfile)` / `update(_:SourceProfile)`。
- 验收:`xcodebuild test -only-testing:LumaPlayerTests/ServerRegistryTests` 全绿 + 新增迁移用例。

### P2 — 搬迁百度 API 层(与 UI 无关)

- ✅ **传输层**:`BaiduPanEndpoint` / `BaiduPanModels` / `BaiduPanError` / `BaiduPanAPIClient`
  (放在 `LumaPlayer/Core/Sources/BaiduPan/`),`CredentialStore` 增加百度
  AppKey/SecretKey/token/片库根的存取。接口事实落在 `docs/BAIDU_PAN_API.md`。
- ✅ **连接层**:`BaiduPanConnection`(actor)—— 授权状态机、`refresh_token` 单飞、
  片库根边界校验、`appendingAccessToken`(只在末尾追加,不做查询串往返)。
- ✅ **播放映射**:`BaiduPanPlaybackPlanner` —— 把 `BaiduPanFile` + `dlink` + 转码地址
  映射成一份 `PlaybackInfo` 响应**形状**,过 main 的 `PlaybackDecisionEngine`
  (⛔ 不接 exp 的 Rust FFI)。为此把决策器拆成
  `decision(for:)`(判定,不含地址)+ `session(for:…)`(按 Emby 地址规则拼会话)。
- ✅ **`seekStrategy` 契约**(原 §10 待拍板项,已按选项 A 落地,见 §6.5)。
- 验收:`BaiduPanEndpointTests` / `BaiduPanDecodingTests` / `BaiduPanCredentialTests` /
  `BaiduPanPlaybackPlannerTests` / `BaiduPanConnectionTests` / `BaiduPanLibraryRootTests` 绿;
  全量 `xcodebuild test` **560 项全绿**,0 warning。
- **踩坑记录(exp 分支遗留,搬运时按语义正确的一边修)**:
  1. 目录条目的 `sizeBytes` 断言为 nil,而实现把服务端的 `size: 0` 原样带出
     → 目录一律 `sizeBytes = nil`(0 字节是「空文件」的意思);
  2. `testDecodesOAuthError` 断言 `invalid_grant` 属于致命 OAuth 码,而实现的白名单里没有它
     → 保持「只认肯定致命的」设计,测试改为断言该意图;
  3. `BaiduPanAuthorization.unconfigured` 这一档**永远返回不到**(`authorization()`
     把配置不全直接抛成错误)→ 改为返回 `.unconfigured`:那是**一屏**,不是错误。

### P3 — 选来源入口 + 连接工厂

- ✅ **入口**:新增 `AddSourceView`(添加流程第一屏 = 选来源类型,引导页与设置页共用);
  `AddServerView` 加 `onBack`(回到「选来源」);新增 `BaiduPanAddView`(添加流程收尾落库)。
- ✅ **连接工厂与来源管理**:`AppContainer` 增加 `baiduConnection()` / `sources()` /
  `source(id:)` / `addBaiduSource(...)` / `registerBaiduSource()` /
  `switchCurrent(to: SourceProfile)` / `removeSource(id:)`(删百度来源时连授权与密钥一起清)。
- ✅ **状态**:`AppState.currentSource: SourceProfile?` 成为权威字段;`currentServer`
  保留为派生访问器(读 Emby 档案、写回 `.emby(_)`)—— Emby 侧 39 个文件零改动。
- ✅ **百度来源页**:`BaiduPanSourceView`(三屏:配密钥 → 扫码 → 浏览目录)/
  `BaiduPanSourceViewModel` / `BaiduPanAuthorizationView` / `BaiduPanBrowserView`。
- ✅ **播放层去 Emby 化**(§10.1 的会话准备协议一并落地):
  - 新增 `PlaybackSessionPreparing`(会话准备)与 `PlaybackReporting`(进度出口)两个协议;
    `PlayerViewModel` 只认协议,`PlaybackSessionCoordinator` 与 `BaiduPanSessionPreparer`
    各是一个实现,由 `AppContainer.makeSessionPreparer/makeReporter(for:)` 按来源装配。
  - `PlaybackRequest.source: PlaybackSource` 枚举(`.emby` / `.baiduPan`),
    保留 `init(server:item:)` 便利构造,4 个既有 Emby 调用点零改动。
  - 续播:新增 `WatchProgressStore` + `LocalResumeReporting`(照 `LocalResumeReporting`
    的约定固定 10 秒落盘);`AppContainer.resumeSeconds(for:fromBeginning:)` 按来源给——
    Emby 读服务端 `UserData`,百度读本地库。
- ✅ **UI 泛化**:`ServerListView` → 来源列表(Emby / 百度平等共存,可切换 / 可删除);
  `BrowseView` 根页按当前来源分派(Emby → 首页;百度 → 它的页);设置页标签改名「来源」。
- 验收:全量 `xcodebuild test` **577 项全绿**(P2 时 560 + 新增 17),0 warning。
- **踩坑记录(P3 期间发现)**:
  1. `WatchProgressStore`(从 exp 移植)落盘用 `.iso8601` 编码,读盘却用默认解码策略
     → `Date` 解不出来,整份文件被判成损坏、续播永远读回 nil。
     已按**对称策略**修(`testSnapshotSurvivesANewStoreInstance` 是这条的守卫)。
  2. `AppState.currentServer` 的 setter 会**整条替换** `currentSource`
     (`currentSource = newValue.map(SourceProfile.emby)`)—— 写 `nil` 会把刚设好的
     百度来源一并抹掉。`addBaiduSource` 里差点顺手写一行 `state.currentServer = nil`。
     ⛔ 派生访问器只读不写 `nil`。

### P4 — 统一条目 + 本地元数据合成

- ✅ `SourceItem` / `SourceItemRef` / `SourceLibrary` / `SourceLibraryRef`;
  `BaiduPanMetadataSynthesizer`(纯函数:文件名解析标题 / 年份 / 季集、挑同目录封面);
  Emby 侧 `EmbyItem → SourceItem` 映射(`EmbySourceItemMapping`);`SourceProvider` 协议
  + `BaiduPanSourceProvider`(列目录 → 合成 → **批量**换封面地址)。
- ⚠️ **「首页/库/搜索逐步改吃 `SourceItem`」没做**:那条整体换血没有收益,
  且首页「继续观看」最后也没跨来源聚合(见 §6.7)。统一形状的收益体现在
  **百度侧**(浏览页现在吃 `SourceItem`)与 P6 的续播卡片。
- 验收:`BaiduPanMetadataSynthesizerTests` / `EmbySourceItemMappingTests` 绿。

### P5 — 图片通路泛化

- ✅ `ImageDescriptor`(`.emby` / `.remote` / `.localFile` 三种 origin + `cacheKey`);
  `PosterImageStore` / `PosterImageLoader` / `PosterDiskCache` 按 descriptor 分派;
  `PosterImage` 增加收 `ImageDescriptor?` 的重载(原 `ImageSpec?` 入口保留);
  百度封面走 `.remote`(`BaiduPanSourceProvider` 批量取 `dlink`)。
- 验收:`ImageDescriptorTests` / `PosterImageTests` / `PosterDiskCacheTests` 绿;
  Emby 卡片不回归(全量测试绿)。

### P6 — 本地续播 + 百度来源页「继续观看」区

- ✅ `WatchProgressStore` 增加**展示快照**(`Entry.display`):播放那一刻把标题 /
  定位 / 封面快照记下来,续播卡片才渲染得出来 —— ⛔ 不回头再列网盘(配额)。
  旧记录没有这个字段,照常解码(向后兼容)。
- ✅ 百度来源页顶部加「继续观看」区(`BaiduPanBrowserView.resumeShelf`):
  跨目录列出本地有进度的条目,卡片显示标题 + 封面 + 「已看到 mm:ss」,可续播 /
  可「移出继续观看」。**这是 Emby 首页那一行的对位物**(决策见 §6.7)。
- ✅ **2026-10-14 交互对齐 Emby 那一行**:点卡片上的播放按钮直接续播,
  点卡片**其余位置**进详情页(此前点整张卡都是直接播)。落点在
  `BaiduPanSourceViewModel.detailDirectory` —— 剧目录优先(季文件夹存法跳过季文件夹)、
  并默认选中卡片那一集所属的季;不是剧的条目落在文件所在目录(⛔ 百度没有单文件详情页)。
- ⛔ `BrowseRoute` **未改**:本次形态下百度页是导航栈根页,续播卡片不 push 任何路由 ——
  「点卡片其余位置进详情页」是**本页内容换一屏**(与手点目录进去同一条路),
  泛化它没有消费者(见 §6.7)。
- 验收:`WatchProgressStoreTests`(快照合并 / 向后兼容 / `resumeEntries` 过滤与排序)、
  `BaiduPanSourceLifecycleTests`(组合根 `rememberResumeCard` 不丢进度、卡片重建)绿;
  全量 **614 项全绿**,0 warning。
- ⚠️ **未验证**:真机上的观感(百度无开发者账号,mock 覆盖)—— 见 §7 与 §10。

## 6. 关键决策

### 6.1 身份用枚举、能力用协议

- **身份**要 `Codable`/`Hashable`/持久化,且 case 集合是**封闭**的(改动时编译器逼你处理所有点)
  → 枚举。
- **能力**会长(WebDAV/本地目录/其它网盘),调用点多 → 协议 + `any SourceProvider`,新增来源不碰调用点。

### 6.2 ⛔ 不给 `ServerProfile` 改名

`ServerProfile` 在 39 个文件里、`ServerRegistry` 在 10 个测试文件里。改名是纯机械劳动、
零功能收益,且会让 diff 淹没真正的改动。做法:`SourceProfile.emby` 直接复用 `ServerProfile`;
`ServerRegistry` 用 typealias 兜住旧名。**名字的抽象留到 P4 之后按需再做。**

### 6.3 百度元数据「本地合成」而非「猜」

- 来源优先级(本地合成这一层):`nfo` > 文件名解析 > 无。
  合成器(`BaiduPanMetadataSynthesizer`)是**纯函数、不认识网络**:
  ⛔ 它自己不联网,⛔ 也不用文件名硬造简介。
- **2026-10-12 补充**:在线刮削(TMDB)是**独立的一层**,接在本地合成**之后**
  —— 文件名解析出的标题 / 年份 → TMDB 查询 → 补封面 / 简介。合成器本身不变。
  事实来源 `docs/TMDB_API.md`;token 由用户在设置里输入,⛔ 不要后端服务器。
  **已接入**(`BaiduPanMetadataScraper`):`BaiduPanSourceProvider.listDirectory` 先出条目,
  再由 ViewModel 起**后台第二趟**刮削 —— 列表先出、封面后补,TMDB 不可达也不挡浏览。
  只补**原来没有值**的字段(`SourceItem.withScrapedMetadata`),用户放在网盘目录里的 `poster.jpg` 优先。
- **2026-10-12 补充(剧集文件夹结构)**:`琅琊榜/01.mp4` 这种「目录名是剧名、文件名只是集号」
  的存法,单个文件名给不出剧名 —— 拿「01」去搜 TMDB 会配回别的片。规则:
  ① 文件名自己认得出剧名时**以文件名为准**(`Show.S01E02.mkv`);
  ② 认不出、且这一层确实像个剧集序列(**同一目录 ≥2 个**这类文件)时,标题取父目录名、
  `kind = .episode`、集号记进 `SourceItem.episodeNumber`;
  ③ 孤零零一个 `300.mp4` **不**当成「《目录名》第 300 集」(那会配错片,硬规则 4)。
  ⚠️ 未支持:`剧名.01.mp4`(标题与集号挤在同一个文件名里)—— 无法与《Ocean's 11》这类片名区分。
- **2026-10-12 补充(刮削钻到分集,Emby 观感)**:剧集条目先 `/3/search/tv` 拿剧(海报 / 简介 /
  首播年),再 `/3/tv/{id}/season/{n}` 拿**该季分集** —— 分集拿到**分集剧照 / 集名 / 单集简介**,
  剧级海报⛔ **不**套给每一集(那是「每集封面都长一样」的成因;`docs/TMDB_API.md` §7/§8)。
  集名进 `SourceItem.episodeTitle`(与剧名 `title` 分开)。季号来自文件名 `SxxExx` 或**季文件夹**
  (`琅琊榜/第13季/01.mp4` → 剧名取祖父目录、季号取父目录);解析不出季号时**默认第 1 季**
  (`BaiduPanMetadataScraper.seasonWhenUnknown`,明说的取舍)—— 局限见 `docs/KNOWN_ISSUES.md`。
  目录卡片另按**剧**查一次拿剧级海报,**只认标题完全一致**(比单条文件的「唯一结果就认」更严);
  ⛔ 电影目录本次不刮(已知限制,见 `docs/KNOWN_ISSUES.md`)。
- 合成不出来的字段一律 `nil`,UI 降级成图标卡,与项目硬规则 4(不静默吞错、不假数据)一致。
- **2026-10-14 补充(目录形态 → 剧集详情页)**:「点进剧集文件夹看到什么」也由这一层定。
  `BaiduPanSeriesLayout`(纯函数)把一层目录判成**普通目录**或**一部剧**:
  ①有季标记子目录(`第13季` / `Season 2` / `S0`,合成器把季号填进 `SourceItem.seasonNumber`)→
  这些子目录就是各季;②否则这一层的集文件(`kind == .episode`)按**第 1 季**处理 ——
  能这么做是因为合成器已经用「同目录 ≥2 个集号型文件名」的闸门把平铺的电影排除了。
  两条都不满足 → 普通目录,⛔ **不猜**:片库里的分类目录(子目录是片名)必须继续走网格。
  判成剧时 `BaiduPanBrowserView` 换成 `BaiduPanSeriesDetailView`(海报 / 简介 / 季 / 分集),
  字段一律「TMDB 能给就显示,给不了就整块隐藏」。限制与未验证项见 `KNOWN_ISSUES.md`。
- **2026-10-14 补充(详情页的剧级扩展信息 + 演职员)**:类型 / 评分 / 标语 / 状态 /
  制片公司 / 电视台 / 演员表 / 导演 / 编剧**不在列目录那一趟**——它们只有详情端点
  (`/3/{tv|movie}/{id}`)与演职员端点(`/3/{tv|movie}/{id}/credits`)才给
  (`docs/TMDB_API.md` §9 / §10)。所以单独一趟,由 `BaiduPanMetadataScraper.seriesProfile`
  在**详情页**发,结果进 `BaiduPanSourceViewModel.seriesProfile`。
  身份来源:① 显式 / 父目录回填的 `tmdbID`;② 否则**剧名 + 年份**——键与判据与分集刮削
  **完全相同**(`searchMatch` 的 `QueryKey`),所以详情页问到的必定是**分集剧照所属的那部剧**,
  且通常命中缓存、零请求;两样都没有时⛔ 一个请求都不发。
  演职员是**整部作品**的(不用 `/3/tv/{id}/season/{n}/credits`),切季不变。
  代价:详情页多 1–2 次请求,⛔ 不合并进 `enrich`(否则一屏三十个目录会多烧六十次)。

### 6.4 不复用 exp 的「形式」

exp 的 `BaiduPanSourceView`(独立 sheet)与 `AddServerView` 侧门按钮**全部弃用**;
只搬它的数据/网络层。这一点是本次改造的出发点。

### 6.5 `seekStrategy` 挂在会话上(2026-10-11 拍板:选项 A)

**问题**:百度转码流**不可拖** —— `method=streaming` 没有起流位置之类的参数,
重新请求只会从头开始(`docs/BAIDU_PAN_API.md` §2.3)。而它和 Emby 的转码流
共用同一个 `PlaybackMethod.transcode`,所以「能不能拖」**从 `plan.method` 推不出来**。

**取舍**:

- 选项 A(选中):`PlaybackSession` 加 `seekStrategy`(`clientSeek` / `restartStream` /
  `unsupported(reason:)`),播放层据此分派;不可拖时不改 `positionSeconds`、
  不上报,只弹一句理由;
- 选项 B(否决):不加,接受「拖动静默回退到 0:00 且把进度写成 0」。

否决 B 的理由:那是一个**既静默又污染进度**的错 —— 用户拖到 30 分钟看到 0:00,
而「继续观看」被写到 0。正是 CLAUDE.md 硬规则 4 要避免的那类。

**落地**:`Core/Playback/PlaybackSeekStrategy.swift`;`PlaybackDecisionEngine` 里
`directStream → .clientSeek`、`transcode → .restartStream`;
`PlayerViewModel.seek(to:)` 三分支分派,`allowsSeeking` 供进度条禁用拖动。

⚠️ **当前状态说明**:`main` 用 libmpv,**没有** AVKit 那张容器能力表,所以百度侧
`dlink` 恒可用 → 判定一律 `directStream` → 百度实际走 `clientSeek`。
`unsupported` 这一档是为「转码流」准备的**契约**,在百度启用转码出口或
`main` 装上能力表之前不会被触发 —— 但契约必须在场,否则那天到来时会静默退化。

### 6.6 ⛔ 百度地址不过 `PlaybackURLBuilder`

实测(2026-10-11,`URLComponents` 往返):

| 输入查询串 | 往返后 |
|---|---|
| `sign=AbC%2BdEf%3D` | `sign=AbC+dEf%3D`(变了) |
| `sign=abcdef123456` | 不变(纯十六进制才侥幸安全) |

`dlink` 的 `sign` 是逐字节校验的,所以百度地址一律**原样采用**,
只在末尾用字符串拼接追加 `access_token`(`BaiduPanConnection.appendingAccessToken`)。
`BaiduPanPlaybackPlannerTests.testDirectStreamURLIsPassedThroughByteForByte`
是这条的回归守卫。

### 6.7 「继续观看」落在百度来源页,不跨来源混排(2026-10-11 拍板)

**背景**:P6 原写「首页「继续观看」聚合两类来源」。但本 App 的首页是**按当前来源
切换根页**的(Emby → `HomeView`;百度 → `BaiduPanSourceView`),没有一个统一的
「首页」可以同时挂两类来源。

**两个候选**:

- 选项 A(选中):**百度来源页顶部加「继续观看」区**,列本地有进度的条目。
  Emby 首页维持只读服务端进度。改动局限在百度侧。
- 选项 B(否决):**Emby 首页那一行里混入百度条目**。需要把百度的标题 / 封面快照
  存进进度库、并在 Emby 首页渲染一张**可播的百度卡片** —— 语义上是把百度内容
  混进「某台 Emby 服务器的首页」,且改动面明显更大。

否决 B 的理由:Emby 首页是**那台服务器**的首页,往里塞另一来源的内容会让
「这一页属于谁」说不清;而 A 用最小的改动满足了真实诉求 ——「百度看一半退出再进,
还能一眼看到接着看」。

**连带决定**:`BrowseRoute` **不改**。原计划让它携带 `SourceItemRef` 是为选项 B
(跨来源 push 详情)铺路;A 之下百度页是栈根、续播卡片直接播,泛化它没有消费者
(同 §6.2 的立场:没有第二个消费者就不抽象)。

**封面怎么来(配额约束下的取舍)**:续播卡片的封面在**播放那一刻**从已合成的
`SourceItem` 折成 `ImageDescriptor.Snapshot` 存进进度库(标题同理)。⛔ 渲染续播区时
**不再列网盘** —— 配额见 §7。快照里的 `dlink` 8 小时过期,
所以封面命中靠磁盘缓存(`cacheKey` 含封面文件 `server_mtime`);缓存也没了就
降级成占位图,⛔ 不假装有封面(同 §6.3)。

## 7. 风险与验收

| 风险 | 处置 |
|---|---|
| 改存储导致旧服务器丢失 | P1 写迁移 + 单测「旧 v1 数据能被读成 `.emby`」 |
| 百度配额极低(配额见 §7) | 复用 exp 的「少发请求」顺序(直连不探流);列表结果本地缓存 |
| 并发报错 | 沿用 CLAUDE.md「并发分层」:新连接类照 `actor`;⛔ 不用 `@unchecked Sendable` |
| 体验合成过度承诺 | 合成器只做**有凭据**的字段;缺就降级,登记 `KNOWN_ISSUES.md` |
| 真机验证 | 本机**无**百度开发者账号,mock 覆盖;真实网盘行为标「未验证」 |

### 8. 明确不做

在线刮削**已改为要做**(2026-10-12:客户端直连 TMDB,见 `docs/TMDB_API.md`;
本条其余项仍不做)、封面下载到沙盒(P5 只预留 `localFile` 分支)、百度写操作、
跨来源统一搜索排序(先各来源内部搜)、把 Emby 的 `EmbyMediaSource` 抽象掉
(P4 只加映射,不改名称)。

## 9. 进度

- [x] P1 存储与身份抽象
- [x] P2 搬迁百度 API 层(传输 + 凭据 + `BaiduPanConnection` + 播放映射 + `seekStrategy` 契约)
- [x] P3 选来源入口 + 连接工厂 + 播放层去 Emby 化 + 本地续播落地
- [x] P4 统一条目 + 本地元数据合成
- [x] P5 图片通路泛化
- [x] P6 本地续播 + 百度来源页「继续观看」区

## 10. 已知待办(下一步从这继续)

P1–P6 全部落地。剩下的都不是「计划内的阶段」,而是**未验证项**与**按需再做**:

1. **未验证项**(本机无百度开发者账号,全部只有 mock 覆盖):
   设备码轮询、真实列表、`dlink` / `method=streaming` 的实际响应、`133`+`adToken` 重试、
   以及 P6 续播区在真机上的观感(封面命中率、续播跳转)。
2. **百度转码出口是否启用**:`main` 眼下恒走直连(见 §6.5 的状态说明)。
   若将来要接 `method=streaming`,`PlaybackSeekStrategy.unsupported` 那一条会立刻生效 ——
   契约已备好,且 `BaiduPanSessionPreparer` 已经会对带位置起流的请求如实报错。
3. **按需再做(本次刻意不做,记在这免得被当成遗漏)**:
   - 跨来源统一首页 / 统一搜索 / `BrowseRoute` 携带 `SourceItemRef`(见 §6.7);
   - `SourceItem` 反向铺到 Emby 的首页 / 库 / 搜索(见 P4 的 ⚠️);
   - `.nfo` sidecar 与 sidecar 封面下载到沙盒(`MetadataOrigin.sidecarNFO` /
     `ImageDescriptor.Origin.localFile` 两条契约已预留,生产者未接,见 §8);
   - `ServerProfile` 改名(见 §6.2)。
