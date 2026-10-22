import CoreGraphics
import Foundation

/// 设计 token(硬约束):所有视图引用本文件数值,⛔ 视图代码里不写间距 / 圆角 / 时长字面量。
/// 字号统一用系统语义字体,唯一例外是播放器时间标签的 `.monospacedDigit()`(不改字号)。
///
/// # 界面规则
///
/// 别处注释里的「DesignTokens.swift「界面规则」」指这一节。
///
/// **信息架构**:主窗口是单个 `NavigationStack`,首页是栈根,媒体库 / 搜索结果 / 详情都 push 上来。
/// 没有系统工具栏与标题栏(`.hiddenTitleBar`,不声明 `.toolbar` 项,push 页隐藏系统返回按钮;
/// ⛔ 不用 `.toolbar(.hidden, for: .windowToolbar)`,会把红绿灯一起藏掉)。
/// 栈外的浮动顶栏(`BrowseChromeBar.swift`)各页共用:左边返回(⌘[,无底 chevron,与红绿灯同高),
/// 右边搜索胶囊(⌘F,回车才搜,仅 Emby)与来源菜单,是玻璃按钮;栏底垫渐变不画「栏」;全屏下随指针自动隐藏
/// (同播放控制栏的双规则)。页面名称与页内工具(排序 / 筛选)在各页 `PageHeader` 里;首页与详情页的 hero 就是标题。
/// 首页 hero(`HomeHeroCarousel` 包 `HomeHero`):随机推荐优先(`Items?SortBy=Random`,池子 20 条筛出带背景图的,最多 5 张),
/// 请求失败才退回「继续观看 → 各库最新」那一张;8 秒自动轮播,可点箭头 / 圆点切,指针悬停或窗口非 key 时停;
/// 没有合格条目就不画(换图不会跳,见 `PITFALLS.md` 第 4 节)。
/// 设置 → 通用 →「首页推荐」关掉时 hero 完全不画、不发推荐请求(⛔ 不走上面的失败退路),首页从「我的媒体」开始
/// (`HomeAppearancePreferences`、`HomeViewModel.heroPick` 的 `recommendationsEnabled`)。
/// hero 文字区:竖版小封面 + 标题 / 元信息 / 两行简介;清晰背景图按 16:9 完整靠右,其余由同图模糊版铺满,
/// 下方过渡带缓动渐变到窗口底色(见 `HomeHero`);首页 ScrollView 关掉顶部滚动边缘效果(否则顶上一条白带)。
/// hero 上只有播放按钮(透明玻璃;电影 / 分集直接播,剧集看过接着看、没看过第一集),⛔ 不给「详情」按钮,点整块画面进详情。
/// 详情页:hero 图透到窗口最上沿,顶栏不放来源菜单(切换会清掉导航栈)。
/// 剧集页分集标题行的「批量标记」菜单(API_CONTRACT.md 5.8)是普通菜单不是玻璃(同行「跳转选集」一致);
/// 逐条串行写,进度显示在「共 N 集」旁,结果用 alert 明示(成功也说,失败带条数与原因)。
/// 来源管理在设置窗口「来源」页。百度目录的「上一层」经 `BrowseChromeController.pageBackAction` 进顶栏。
///
/// **加载态**:首屏无内容时用灰色骨架(`Skeleton*`)照真实布局占位;刷新、失败都保留旧内容;
/// 「在不在加载」只看顶栏下沿的加载线(`ChromeLoadingLine`);加载中整页不可点。
/// 手动刷新是菜单栏 View →「Reload」(⌘R),⛔ 顶栏不放常驻刷新按钮。
/// 加载成功但为空的首页行整行不显示;「我的媒体」的加载 / 失败态必须显示。
///
/// **Liquid Glass**:只用于临时、可操作、浮在内容上的元素 —— 播完卡片 / 下一集提示、主窗口顶栏按钮与搜索胶囊、
/// 字幕 / 音轨 / 倍速浮层、屏显提示胶囊、详情页播放主按钮(可带轻 tint)、首页 hero 播放按钮
/// (不带 tint 的 `.glass`,⛔ 不用 `.glassProminent`:系统强调色的饱和蓝压在照片上突兀)。
/// ⛔ 不用于:海报卡片、列表 / 剧集的每一行、长文本背景、全窗口背景、播放器底部控制栏
/// (全宽横条 + 自下而上黑色渐变压暗:HIG 要求玻璃压在媒体上配 dimming,Apple TV / QuickTime / mpv OSC 都是全宽横条)。
/// 相邻玻璃用 `GlassEffectContainer(spacing: Metrics.spacingM)` 包,容器 spacing 必须等于内部间距
/// (大了静止时糊成一团);⛔ `.interactive()` 是 iOS-only,不写;⛔ 不从海报取色生成 tint。
///
/// **播放窗口**:顶部只有一行标题(剧名 + SxEy · 集名,`HStack` 基线对齐),诊断信息(串流方式、容器)只在统计 overlay(I)里。
/// 控制栏自左向右:播放 / 暂停(上一集、下一集紧贴左右,外侧才是 ±`seekStep` 跳转)→ 音量 → 倍速、字幕、音轨(两个独立菜单)、
/// 播放选项 → 选集(最右端)。⛔ 控制栏不放全屏图标(F 与双击画面已够,最右让给选集)。
/// 播放键不固定最左:没有上下集时那一簇收窄。进度条两端显示时间,右侧可点切成「预计结束时刻」(倍速参与换算,算不出退回剩余时长)。
/// 自动隐藏两条规则都要:指针静止 `autoHideDelay`、移出窗口 `autoHidePointerExitDelay`;暂停 / 错误 / 缓冲 / 播完 /
/// 倍速浮层打开时不隐藏。前后跳转连点累加(第 n 次跳 `seekStep × n`,上限 `seekRepeatMaxMultiple`)。
/// 正在播放时切服务器:先结束旧播放会话再切。
///
/// **错误**:只显示可操作信息(「登录已过期,请重新登录」),⛔ 不显示 token、完整播放 URL、原始服务端异常;
/// 持续性错误用页面级 `ErrorStateView` + 重试;服务器失败只在对应分区提示,不用全窗口遮罩。
///
/// **无障碍**:颜色不是状态的唯一表达(要有图标 / 文本);图标按钮都有 `accessibilityLabel` 与 tooltip;
/// 「减少透明度」下玻璃退化为可读的实色材质,「减少动态效果」下动画直接切换;播放时间的 VoiceOver 更新要节流。
///
/// **性能**:列表 / 网格不逐项 `.glassEffect()`;播放时间更新只重绘进度视图,不能带着整个播放器每帧重绘。

/// 间距与布局尺寸
enum Metrics {
    // MARK: 间距

    /// 胶囊标签的上下内边距
    static let spacingXXS: CGFloat = 2
    /// 图标与文字之间
    static let spacingXS: CGFloat = 4
    /// 同组元素内部
    static let spacingS: CGFloat = 8
    /// 玻璃容器内部、卡片之间(与 GlassEffectContainer(spacing:) 一致)
    static let spacingM: CGFloat = 12
    /// 分组之间、网格间距
    static let spacingL: CGFloat = 16
    /// 页面边距、区块之间
    static let spacingXL: CGFloat = 24
    /// 详情页正文最大宽度
    static let contentMaxWidth: CGFloat = 680

    // MARK: 表单

    /// 添加服务器 / 重新登录表单的宽度(sheet 与首次启动引导页共用)
    static let onboardingFormWidth: CGFloat = 460
    /// 表单主按钮最小宽度(两个字也有足够点击面积)
    static let onboardingPrimaryButtonMinWidth: CGFloat = 64

    /// 服务器列表行首图标边长
    static let serverRowIconSize: CGFloat = 36

    // MARK: 主窗口

    /// 主窗口默认尺寸
    static let mainWindowWidth: CGFloat = 1280
    static let mainWindowHeight: CGFloat = 800

    // MARK: 主窗口浮动顶栏(`BrowseChromeBar.swift`)

    /// 普通页面内容从这里往下排;hero 页的图铺满,栏压在图上
    static let chromeBarHeight: CGFloat = 52
    /// 窗口化时返回按钮左缩进,让出红绿灯(右缘约 63pt)
    static let chromeBarLeading: CGFloat = 72
    /// 返回 chevron 的点击区域边长
    static let chromeBackHitSize: CGFloat = 28
    /// 平时的不透明度,悬停到 1(无底按钮的悬停反馈)
    static let chromeBackIdleOpacity: Double = 0.75
    static let chromeSearchWidth: CGFloat = 180
    /// 与 `.large` 玻璃圆形按钮等高
    static let chromeSearchHeight: CGFloat = 32
    /// 普通页面栏底:窗口底色实色部分占栏高的比例,往下渐变到透明
    static let chromeScrimSolidFraction: Double = 0.55
    /// hero 页栏底顶端黑色的不透明度(让红绿灯与玻璃按钮读得出来)
    static let chromeHeroScrimOpacity: Double = 0.35
    static let chromeLoadingLineHeight: CGFloat = 2
    /// 扫动那一段占整条宽度的比例
    static let chromeLoadingLineSegmentFraction: CGFloat = 0.25
    /// 扫一趟的秒数
    static let chromeLoadingLinePeriod: TimeInterval = 1.2
    /// 「减少动态效果」下静止加载线的不透明度
    static let chromeLoadingLineStaticOpacity: Double = 0.6

    // MARK: 设置窗口

    /// 「服务器」页要放得下一行的名称 / 地址 / 账户 / 版本
    static let settingsWindowWidth: CGFloat = 560
    static let settingsWindowHeight: CGFloat = 420
    /// 滑块右侧数值标签的最小宽度(不随数值宽窄跳动)
    static let settingsValueWidth: CGFloat = 64
    /// 字幕颜色预设色块直径
    static let colorSwatchSize: CGFloat = 22

    // MARK: 播放器控制栏

    /// 全宽横条里内容仍要缩进,不顶到窗口边缘
    static let controlBarSideInset: CGFloat = 32
    static let controlBarBottomInset: CGFloat = 16
    /// 进度条与画面之间的留白
    static let controlBarTopInset: CGFloat = 20
    /// 底部压暗渐变底端的不透明度:亮画面下白字才读得出(HIG 要求媒体上的浮层配 dimming,参考值 35%)
    static let controlBarScrimOpacity: Double = 0.55
    /// 压暗渐变起始高度(占控制栏总高的比例),往上完全透明
    static let controlBarScrimStart: Double = 0.05
    /// 指针静止多久后隐藏控制栏,每次移动重置(与 mpv OSC `fadedelay` 同量级)
    static let autoHideDelay: TimeInterval = 2
    /// 指针移出窗口后多久隐藏
    static let autoHidePointerExitDelay: TimeInterval = 0.3
    /// 恢复播放 / 菜单操作后额外等待,避免刚有动作就隐藏
    static let autoHideResumeDelay: TimeInterval = 5
    /// 方向键单次 seek 的默认档(设置页可改,`PlaybackPreferences.seekStep`)。
    /// 转码模式下是停流 + StartTimeTicks 重新起流(API_CONTRACT.md 4.5),由 PlayerViewModel 分派。
    static let seekStep: TimeInterval = 10
    /// Shift+方向键
    static let seekStepLarge: TimeInterval = 30
    /// 设置页可选的跳转步长;`seekStep` 必须是其中之一
    static let seekStepOptions: [TimeInterval] = [5, 10, 15, 30]
    /// 转码 seek 的重新起流合并窗口:每次重新起流约 4 个请求且拆一次会话,等连点停下再起
    /// (`docs/PITFALLS.md` 第 4 节)。⛔ 不用于 DirectStream:mpv seek 本来就便宜,合并只会变慢。
    static let seekRestartMergeDelay: TimeInterval = 0.25
    /// 连点累加上限(倍):第 n 次跳 `seekStep × n`,不设上限连点几十次会一次跳走几小时
    static let seekRepeatMaxMultiple: Int = 5
    /// 超过这个时间没再点就从 1 倍重新开始
    static let seekRepeatResetDelay: TimeInterval = 1.2
    static let volumeStep: Double = 5
    /// mpv `--volume`
    static let volumeRange: ClosedRange<Double> = 0...100
    /// mpv 默认音量,也是「默认音量」偏好的默认值
    static let defaultVolume: Double = 100
    /// 与 `MPVPlayer.setSpeed` 的夹取一致(超出音频严重失真)
    static let speedRange: ClosedRange<Double> = 0.25...4
    /// 倍速滑块与浮层 ± 按钮的步长(连续调节)
    static let speedStep: Double = 0.05
    /// `[` `]` 的步长,比滑块粗一档
    static let speedKeyStep: Double = 0.1
    /// 连续调倍速时的上报合并窗口(`PlayerViewModel.scheduleRateChangeReport`)
    static let speedReportDelay: TimeInterval = 0.5

    /// 夹到倍速区间并抹到两位小数(滑块拖出的浮点尾数会让屏显与上报抖)。
    /// 非有限值兜在 1×:NaN 进 Slider 的 binding 会直接崩。
    static func clampedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let clamped = min(max(value, speedRange.lowerBound), speedRange.upperBound)
        return (clamped * 100).rounded() / 100
    }
    /// 字幕延迟区间(秒)。mpv 不设限;超过 ±60 秒是字幕配错了版本,调偏移救不回来
    static let subtitleDelayRange: ClosedRange<Double> = -60...60
    /// Z / X(同 mpv 默认键位)
    static let subtitleDelayStep: Double = 0.1
    /// ⇧Z / ⇧X
    static let subtitleDelayLargeStep: Double = 1
    /// 播放器图标按钮的点击区域边长(统一,避免图标宽窄不一导致跳动)
    static let playerButtonSize: CGFloat = 32
    /// 屏显提示停留时长
    static let osdDuration: TimeInterval = 1.2
    // MARK: 进度条

    static let scrubberTrackHeight: CGFloat = 4
    /// 悬停 / 拖动时
    static let scrubberTrackHeightActive: CGFloat = 7
    /// 播放头圆点直径(mpv OSC `seekbarstyle=knob` 的做法)
    static let scrubberKnobSize: CGFloat = 11
    /// 悬停 / 拖动时
    static let scrubberKnobSizeActive: CGFloat = 15
    /// 轨道底色 / 已播放 / 已缓冲,层次靠这三个不透明度拉开
    static let scrubberTrackOpacity: Double = 0.28
    static let scrubberPlayedOpacity: Double = 1.0
    static let scrubberBufferedOpacity: Double = 0.55
    /// 悬停时间气泡距轨道的垂直距离
    static let scrubberTooltipOffset: CGFloat = 28

    /// 片头 / 片尾标记画在已播放段之上,要压得住白色又不盖掉位置信息
    static let scrubberMarkerOpacity: Double = 0.95
    /// 片尾起点竖条宽度
    static let scrubberMarkerWidth: CGFloat = 2
    /// 片头很短时也要看得见
    static let scrubberMarkerMinWidth: CGFloat = 3
    /// 续播时从服务端记录位置往回退的秒数
    static let resumeRewind: TimeInterval = 5
    /// 片头最后几秒不再显示「跳过片头」(`PlaybackMarkers.isInIntro`)
    static let skipIntroTailTolerance: TimeInterval = 1
    /// 「下一集」倒计时秒数
    static let upNextCountdown = 10
    /// 没有片尾标记时结束前多少秒提示下一集(与倒计时等长:数完正好播完)
    static let upNextFallbackLead: TimeInterval = 10
    /// 缓冲进度 / 已缓存范围 / 统计信息的轮询间隔
    static let playerMonitorInterval: TimeInterval = 1
    /// 触控板横向双指滑动每 1 pt 对应的秒数
    static let trackpadSeekSecondsPerPoint: Double = 0.2
    /// 横向累计位移超过纵向的这么多倍才算拖进度,否则放行给系统
    static let trackpadHorizontalDominance: Double = 1.5
    /// 起判的最小横向累计位移(pt),滤掉手指搭上时的抖动
    static let trackpadActivationDistance: Double = 6
    /// 跳过片头 / 下一集提示距窗口底部(要让出控制栏)
    static let playerPromptBottomInset: CGFloat = 100

    // MARK: 分集面板(播放页右侧滑出的选集抽屉)

    /// ⛔ 不铺满:要能和画面并存,一边看一边挑
    static let episodePanelWidth: CGFloat = 380
    /// 缩略图宽度(16:9);`ImageSpec.maxWidth` 取它的两倍
    static let episodeThumbnailWidth: CGFloat = 132
    /// 材质上再叠一层固定暗底:视频亮度不可控,只靠玻璃压不住
    static let episodePanelDimOpacity: Double = 0.55
    /// 把手贴在抽屉左缘外侧,不占 `episodePanelWidth`
    static let episodePanelCollapseHandleWidth: CGFloat = 22
    /// 竖直居中的短条,不做满高(会像一条边框)
    static let episodePanelCollapseHandleHeight: CGFloat = 84

    // MARK: 海报网格

    static let posterMinWidth: CGFloat = 150
    /// 宽 / 高
    static let posterAspectRatio: Double = 2.0 / 3.0
    /// 「我的媒体」磁贴与「继续观看 / 下一集」卡片
    static let landscapeAspectRatio: Double = 16.0 / 9.0
    /// 「我的媒体」磁贴
    static let libraryTileWidth: CGFloat = posterMinWidth * 1.2
    /// 「继续观看 / 下一集」横版卡片
    static let landscapeCardWidth: CGFloat = posterMinWidth * 1.6
    static let gridSpacing: CGFloat = spacingL

    // MARK: 详情页 hero

    /// 按 `contentMaxWidth` 算高度
    static let heroAspectRatio: Double = 9.0 / 16.0
    /// 只有竖版海报(百度)时放大 + 模糊当背景,海报另画一份清晰的
    static let heroBackdropBlur: CGFloat = 24
    /// 模糊会把边缘吃虚,放大一点补满
    static let heroBackdropScale: CGFloat = 1.2
    /// 压暗后标题才读得清
    static let heroBackdropDimOpacity: Double = 0.45
    /// 标题区向上压进背景的比例
    static let heroOverlapRatio: CGFloat = 0.45

    // MARK: 首页 hero(`HomeHero`)

    /// 图片区高度 = 宽度 × 比例,再夹到上下限(总高再加 `homeHeroFadeBand`)。
    /// 用户定的尺寸:首屏要露出「我的媒体」和「继续观看」两行,⛔ 不调大
    static let homeHeroHeightRatio: CGFloat = 0.32
    static let homeHeroMinHeight: CGFloat = 300
    static let homeHeroMaxHeight: CGFloat = 500
    /// 背景图请求的宽度档位(像素,必带,API_CONTRACT.md 3.3)
    static let homeHeroImageMaxWidth: CGFloat = 1920
    /// backdrop 标准宽高比。清晰图按图片区高度完整摆放、靠右;⛔ 不铺满整宽(宽窗口下会放大并裁掉上下)
    static let homeHeroImageAspect: CGFloat = 16.0 / 9.0
    /// 清晰图左边由同一张图整宽铺满后重度模糊填上(同一 spec,命中缓存)。
    /// ⛔ 别调轻:模糊一轻就看得出和右边是同一批人物(更轻的值、镜像、拉伸边缘都被用户否了)
    static let homeHeroAmbientBlur: CGFloat = 60
    /// 图片区下方过渡带:模糊底图渐变到窗口底色,货架从它下面接上。
    /// ⛔ 不在底边硬切成白色,⛔ 不让清晰图线性淡出成白雾
    static let homeHeroFadeBand: CGFloat = 72
    /// 左侧文字区压暗:最左端黑色的不透明度
    static let homeHeroSideScrimOpacity: Double = 0.55
    /// 渐变到透明的位置(占宽度的比例)
    static let homeHeroSideScrimEnd: Double = 0.6
    /// 竖版小封面宽度,与海报卡片同宽 → 命中卡片的图片缓存
    static let homeHeroPosterWidth: CGFloat = posterMinWidth
    static let homeHeroOverviewMaxWidth: CGFloat = 560
    /// Logo 只是装饰(文字标题始终在它下面),所以小一号
    static let homeHeroLogoMaxWidth: CGFloat = 280
    static let homeHeroLogoMaxHeight: CGFloat = 72
    /// 续播进度条宽度
    static let homeHeroProgressWidth: CGFloat = 220
    /// 没有 backdrop 时模糊海报底图的半径:小竖图拉到整窗宽,轻模糊看得出放大的五官,只当色调用
    static let homeHeroFallbackBlur: CGFloat = 80
    /// 轮播分页圆点直径,比系统 `PageControl` 小一号,不抢文字区注意力
    static let heroDotSize: CGFloat = 7

    // MARK: 批量标记分集(`SeasonPlayedPickerSheet`,API_CONTRACT.md 5.8)

    /// 与 `DanmakuPickerSheet` / `PlayerMarkersEditor` 同一量级
    static let playedPickerWidth: CGFloat = 520
    /// 集多时滚动
    static let playedPickerListMaxHeight: CGFloat = 420
    /// 清单高度按行数算(`SeasonPlayedPickerSheet.listHeight`),⛔ 不把 `List` 丢进弹性容器
    /// (集少时下方空一大片、集多时被硬裁)
    static let playedPickerRowHeight: CGFloat = 24

    // MARK: 分集货架滚动条

    /// 不画轨道,只有滑块
    static let shelfScrubberThumbHeight: CGFloat = 8
    /// 集数极多时留一个能点中的下限
    static let shelfScrubberThumbMinWidth: CGFloat = 28
    /// 可点击高度,比可见滑块高
    static let shelfScrubberHitHeight: CGFloat = 20
    static let shelfScrubberThumbOpacity: Double = 0.3
    /// 悬停 / 拖动时
    static let shelfScrubberThumbOpacityHover: Double = 0.55
    /// 停止滚动后淡出的延迟(同系统覆盖式滚动条)
    static let shelfScrubberHideDelay: TimeInterval = 1.0

    // MARK: 动画时长

    /// 按钮悬停、按下反馈
    static let animationFast: TimeInterval = 0.15
    /// 控制栏淡入淡出、浮层出现
    static let animationStandard: TimeInterval = 0.25
    /// 全屏过渡
    static let animationSlow: TimeInterval = 0.4
}

/// 圆角
enum Radius {
    /// 海报卡片、非玻璃卡片
    static let card: CGFloat = 8
    /// 浮层面板
    static let panel: CGFloat = 12
}
