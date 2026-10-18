import CoreGraphics
import Foundation

/// 设计 token(硬约束):所有视图必须引用本文件数值,
/// ⛔ 禁止在视图代码里写间距 / 圆角 / 时长字面量。
/// 字号统一用系统语义字体,唯一例外是播放器时间标签的
/// `.monospacedDigit()`(等宽数字,不改字号)。
///
/// # 界面规则
///
/// 别处注释里写「DesignTokens.swift「界面规则」」的,指的就是这一节。
///
/// **信息架构**:主窗口是单个 `NavigationStack`,首页是栈根,媒体库 / 搜索结果 / 详情都 push 上来。
/// **没有系统工具栏与标题栏**(窗口 `.hiddenTitleBar`,不声明 `.toolbar` 项,push 页隐藏系统返回按钮;
/// ⛔ 不用 `.toolbar(.hidden, for: .windowToolbar)`,它会把红绿灯一起藏掉):
/// 挂在栈外的浮动顶栏(`BrowseChromeBar.swift`)各页共用 —— 左边返回(⌘[,无底 chevron,与红绿灯同高),右边搜索胶囊(⌘F,
/// 提交式,回车才搜;仅 Emby)、来源菜单,是玻璃按钮,栏底垫渐变不画「栏」;
/// 全屏下随指针自动隐藏(与播放控制栏同一套双规则)。页面名称与页内工具(排序 / 筛选)在
/// 各页的 `PageHeader` 大标题行里;首页与详情页不用它,hero 就是标题。
/// 首页顶部 hero(`HomeHeroCarousel` 包 `HomeHero`):**随机推荐**优先(`Items?SortBy=Random`,
/// 池子 20 条筛出带背景图的取最多 5 张),拿不到才退回「继续观看 → 各库「最新」」那**一张**;
/// 8 秒自动轮播,可点箭头 / 圆点手动切,指针悬停或窗口非 key 时停;没有合格条目就不画。
/// ⚠️ 2026-10-15 之前是「继续观看第一项、单张、⛔ 不轮播」,那条已作废(旧理由「换图会跳」不成立,
/// 见 `PITFALLS.md` 第 4 节)。
/// ⚠️ 设置 → 通用 →「首页推荐」可以整块关掉:关掉时 hero **完全不画**(⛔ 不走「继续观看 / 各库最新」
/// 退路,那条只是**请求失败**时的容错),首页直接从「我的媒体」开始,也不发推荐请求
/// (`HomeAppearancePreferences`、`HomeViewModel.heroPick` 的 `recommendationsEnabled`)。
/// hero 文字区:竖版小封面 + 标题 / 元信息 / 两行简介;清晰背景图按 16:9 完整靠右摆放,
/// 其余由同一张图的模糊版铺满,下方一段过渡带缓动渐变到窗口底色(细节见 `HomeHero` 类型注释);首页 ScrollView 关掉顶部滚动边缘效果(那是顶上的白带)。
/// hero 上**只有播放按钮**(透明玻璃;电影 / 分集直接播,剧集点了再定位分集:看过接着看、
/// 没看过第一集),⛔ 不给「详情」按钮 —— 进详情靠点整块画面。
/// 详情页:hero 图透到窗口最上沿,顶栏不放来源菜单(切换会清掉导航栈)。
/// 剧集页的分集标题行有「批量标记」菜单(整季已看 / 未看 + 勾选分集…,API_CONTRACT.md 5.8):
/// 它是**普通菜单**不是玻璃,与同一行的「跳转选集」一致;逐条串行写,进度显示在这一行
/// 左侧「共 N 集」旁边,结果用 alert 明示(成功也说一声,失败带条数与原因)。
/// 来源管理在设置窗口「来源」页。百度目录的「上一层」经 `BrowseChromeController.pageBackAction` 进顶栏。
///
/// **加载态**:首屏无内容时用灰色骨架(`Skeleton*`)照真实布局占位;刷新时保留旧内容,
/// 失败也保留;「在不在加载」只看顶栏下沿那条加载线(`ChromeLoadingLine`);加载中整页不可点。
/// 手动刷新是菜单栏 View →「Reload」(⌘R),⛔ 不在顶栏放常驻的刷新按钮。
/// 加载成功但为空的首页行整行不显示;「我的媒体」的加载 / 失败态必须显示。
///
/// **Liquid Glass**:只用于临时、可操作、浮在内容上的元素 —— 播完卡片 / 下一集提示、
/// 主窗口浮动顶栏的按钮与搜索胶囊、字幕 / 音轨 / 倍速浮层、屏显提示胶囊、详情页播放主按钮(可带轻 tint)、
/// 首页 hero 的播放按钮(**不带 tint 的透明玻璃** `.glass`,⛔ 不用 `.glassProminent`:它吃系统强调色,
/// 一块饱和蓝压在照片上很突兀;中间试过白底实心胶囊,用户要透明玻璃,2026-10-15)。
/// ⛔ 不用于:海报卡片、列表 / 剧集的每一行、长文本背景、全窗口背景、**播放器底部控制栏**
/// (它是全宽横条 + 自下而上的黑色渐变压暗:HIG 要求玻璃压在媒体上配 dimming,
/// 且 Apple TV / QuickTime / mpv OSC 默认都是全宽横条)。
/// 相邻玻璃用 `GlassEffectContainer(spacing: Metrics.spacingM)` 包,容器 spacing 必须**等于**内部间距
/// (大了会在静止时糊成一团);⛔ `.interactive()` 是 iOS-only,不写;⛔ 不从海报取色生成 tint。
///
/// **播放窗口**:顶部只有一行标题(剧名 + SxEy · 集名,`HStack` 基线对齐),诊断信息
/// (串流方式、容器)只在统计 overlay(I)里。控制栏自左向右:播放 / 暂停(**上一集、下一集紧贴它
/// 左右**,外侧才是 ±`seekStep` 的前后跳转)→ 音量 → 倍速、字幕、音轨(两个独立菜单)、
/// 播放选项 → **选集(最右端)**。⛔ 控制栏不再有全屏图标:F 与双击画面两条通路已够,
/// 最右这个位置让给播剧时反复要点的选集(2026-10-14)。⛔ 也因此不要指望「播放键固定最左」:
/// 没有上下集的条目那一簇会收窄,播放键跟着左移。进度条两端显示时间,右侧可点切成
/// 「预计结束时刻」(倍速参与换算,算不出就退回剩余时长)。自动隐藏是两条规则都要:指针静止
/// `autoHideDelay`、移出窗口 `autoHidePointerExitDelay`;暂停 / 错误 / 缓冲 / 播完时不隐藏;
/// 倍速浮层打开时不隐藏。前后跳转连点累加(第 n 次跳 `seekStep × n`,上限 `seekRepeatMaxMultiple`)。
/// 正在播放时切服务器:先结束旧播放会话再切。
///
/// **错误**:只显示可操作信息(「登录已过期,请重新登录」),⛔ 不显示 token、完整播放 URL、原始服务端异常;
/// 持续性错误用页面级 `ErrorStateView` + 重试;服务器失败只在对应分区提示,不用全窗口遮罩。
///
/// **无障碍**:颜色不是状态的唯一表达(要有图标 / 文本);图标按钮都有 `accessibilityLabel` 与 tooltip;
/// 「减少透明度」下玻璃退化为可读的实色材质,「减少动态效果」下动画直接切换;
/// 播放时间的 VoiceOver 更新要节流。
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
    /// 表单主按钮最小宽度(「连接」「登录」两个字也有足够的点击面积)
    static let onboardingPrimaryButtonMinWidth: CGFloat = 64

    /// 服务器列表行首图标的边长
    static let serverRowIconSize: CGFloat = 36

    // MARK: 主窗口

    /// 主窗口默认尺寸;内容页与详情页都是整页(见上方「界面规则」),不再有列宽。
    static let mainWindowWidth: CGFloat = 1280
    static let mainWindowHeight: CGFloat = 800

    // MARK: 主窗口浮动顶栏(`BrowseChromeBar.swift`)

    /// 顶栏高度。普通页面的内容从这里往下排;hero 页的图铺满,栏压在图上。
    static let chromeBarHeight: CGFloat = 52
    /// 窗口化时返回按钮的左缩进:让出系统红绿灯那一列(红绿灯右缘约在 63pt)
    static let chromeBarLeading: CGFloat = 72
    /// 返回 chevron 的点击区域边长(图标本身小,点击区要够大)
    static let chromeBackHitSize: CGFloat = 28
    /// 返回 chevron 平时的不透明度;悬停时到 1(无底按钮靠这个给悬停反馈)
    static let chromeBackIdleOpacity: Double = 0.75
    /// 搜索胶囊里输入框的宽度
    static let chromeSearchWidth: CGFloat = 180
    /// 搜索胶囊高度(与 `.large` 玻璃圆形按钮等高)
    static let chromeSearchHeight: CGFloat = 32
    /// 普通页面的栏底:窗口底色实色部分占栏高的比例,再往下渐变到透明
    static let chromeScrimSolidFraction: Double = 0.55
    /// hero 页的栏底:顶端黑色的不透明度(只为让红绿灯与玻璃按钮读得出来)
    static let chromeHeroScrimOpacity: Double = 0.35
    /// 栏下沿加载线的高度
    static let chromeLoadingLineHeight: CGFloat = 2
    /// 加载线里扫动那一段占整条宽度的比例
    static let chromeLoadingLineSegmentFraction: CGFloat = 0.25
    /// 扫一趟的时长(秒)
    static let chromeLoadingLinePeriod: TimeInterval = 1.2
    /// 「减少动态效果」下静止加载线的不透明度
    static let chromeLoadingLineStaticOpacity: Double = 0.6

    // MARK: 设置窗口

    /// 设置窗口的尺寸(「服务器」标签页要放得下一行的名称 / 地址 / 账户 / 版本)
    static let settingsWindowWidth: CGFloat = 560
    static let settingsWindowHeight: CGFloat = 420
    /// 设置页滑块右侧数值标签的最小宽度(「100%」「上移 25%」不随数值宽窄跳动)
    static let settingsValueWidth: CGFloat = 64
    /// 设置页颜色色块的直径(字幕颜色预设)
    static let colorSwatchSize: CGFloat = 22

    // MARK: 播放器控制栏

    /// 控制栏距窗口左右边缘的内边距。全宽横条的排版里,内容仍然要缩进,
    /// 不能顶到窗口边缘。
    static let controlBarSideInset: CGFloat = 32
    /// 控制栏距窗口底部
    static let controlBarBottomInset: CGFloat = 16
    /// 控制栏顶部的留白(进度条与画面之间的呼吸位)
    static let controlBarTopInset: CGFloat = 20
    /// 底部压暗衬底的不透明度。
    ///
    /// HIG Materials 明确:玻璃浮在 media background 上必须配 dimming layer,
    /// Apple 给的参考值是 35%。这里不用玻璃(理由见上方「界面规则」),
    /// 用自下而上的黑色渐变,底端取这个值 —— 视频亮画面下白字才读得出来。
    static let controlBarScrimOpacity: Double = 0.55
    /// 压暗衬底的起始高度(占控制栏总高的比例),再往上完全透明
    static let controlBarScrimStart: Double = 0.05
    /// 指针**静止**在窗口里多久后隐藏控制栏。
    ///
    /// 每次指针移动都会重置这个计时。mpv OSC 的 `fadedelay` 默认就是这个量级;
    /// 太短会让人来不及把指针移到控制栏上,太长则控制栏一直压在画面上。
    static let autoHideDelay: TimeInterval = 2
    /// 指针**移出窗口**后多久隐藏。比 `autoHideDelay` 短 —— 指针都不在窗口里了,
    /// 没有任何继续显示它的理由。
    static let autoHidePointerExitDelay: TimeInterval = 0.3
    /// 恢复播放 / 菜单操作后额外等待(避免刚有动作就隐藏)
    static let autoHideResumeDelay: TimeInterval = 5
    /// 方向键单次 seek
    ///
    /// 转码模式下不是 mpv seek,而是停流 + StartTimeTicks 重新起流
    /// (API_CONTRACT.md 4.5);token 值相同,行为由 PlayerViewModel 分派。
    /// 可在设置页改(`PlaybackPreferences.seekStep`),这个值是默认档。
    static let seekStep: TimeInterval = 10
    /// Shift+方向键单次 seek
    static let seekStepLarge: TimeInterval = 30
    /// 设置页可选的跳转步长(秒);`seekStep` 必须是其中之一
    static let seekStepOptions: [TimeInterval] = [5, 10, 15, 30]
    /// 转码 seek 的重新起流合并窗口(秒)
    ///
    /// 连点前进 / 后退时,每次点击都是一次「停流 + 重新起流」——
    /// 最终 Progress + Stopped + Playing + PlaybackInfo,约 4 个请求,
    /// 连点 5 下就是 ~20 个请求 / 1 秒内,而且每轮都拆一次会话。
    /// 同一个坑倍速改滑块时踩过一次(`docs/PITFALLS.md` 第 4 节:
    /// 「凡是从离散选项改成连续调节的控件,都要回头看它的副作用是按次
    /// 还是按值触发」),所以这里等连点停下来再起流。
    ///
    /// ⛔ 不适用于 DirectStream:那是 mpv seek,本来就便宜,合并只会让
    /// 画面响应变慢。窗口 0.25 秒:短到感觉不到,长到足以吃掉连点。
    static let seekRestartMergeDelay: TimeInterval = 0.25
    /// 连点后退 / 前进时的累加上限(倍)。第 n 次点击跳 `seekStep × n`,
    /// 到这个倍数就不再加了(Apple TV 是「Click again to skip another 10 seconds」,
    /// Plex 同类;不加上限的话连点几十次会一次跳走几小时)。
    static let seekRepeatMaxMultiple: Int = 5
    /// 连点累加的归零间隔:超过这个时间没再点就重新从 1 倍开始
    static let seekRepeatResetDelay: TimeInterval = 1.2
    /// 音量单次增减(0–100)
    static let volumeStep: Double = 5
    /// 音量区间(mpv `--volume`)
    static let volumeRange: ClosedRange<Double> = 0...100
    /// mpv 自身的默认音量(`--volume` 默认 100),也是「默认音量」偏好的默认值
    static let defaultVolume: Double = 100
    /// 倍速区间:与 `MPVPlayer.setSpeed` 的夹取一致(超出这个范围音频严重失真)
    static let speedRange: ClosedRange<Double> = 0.25...4
    /// 倍速滑块与浮层 ± 按钮的步长(连续调节,不按档位跳)
    static let speedStep: Double = 0.05
    /// `[` `]` 的步长:比滑块粗一档,一次按键要有明显变化
    static let speedKeyStep: Double = 0.1
    /// 连续调倍速时的上报合并窗口(见 `PlayerViewModel.scheduleRateChangeReport`)
    static let speedReportDelay: TimeInterval = 0.5

    /// 夹到倍速区间,并把值抹到两位小数 —— 连续拖滑块会拖出 `1.1500000000000001`
    /// 这种浮点尾数,屏显与上报都会跟着抖。非有限值不该出现;真出现时兜在 1×:
    /// NaN 进 Slider 的 binding 会直接崩。
    static func clampedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let clamped = min(max(value, speedRange.lowerBound), speedRange.upperBound)
        return (clamped * 100).rounded() / 100
    }
    /// 字幕延迟区间(秒)。mpv 本身不设限;±60 秒已远超「同一个文件的字幕对不齐」的量级,
    /// 再大就是字幕配错了版本,调偏移救不回来
    static let subtitleDelayRange: ClosedRange<Double> = -60...60
    /// Z / X 的字幕延迟步长(mpv 默认键位也是 0.1 秒)
    static let subtitleDelayStep: Double = 0.1
    /// ⇧Z / ⇧X 的大步长:差好几秒时不用连按几十下
    static let subtitleDelayLargeStep: Double = 1
    /// 播放器图标按钮的点击区域边长(控制栏与菜单按钮一致,避免图标宽窄不一导致跳动)
    static let playerButtonSize: CGFloat = 32
    /// 屏显提示(OSD,如「1.25×」「字幕:中文」)停留时长
    static let osdDuration: TimeInterval = 1.2
    // MARK: 进度条

    /// 进度条静止时的轨道高度
    static let scrubberTrackHeight: CGFloat = 4
    /// 悬停 / 拖动时的轨道高度
    static let scrubberTrackHeightActive: CGFloat = 7
    /// 播放头圆点直径(静止)。Apple 在 Liquid Glass 里把播放头「从小变得更大更显眼」,
    /// 圆点是 mpv OSC `seekbarstyle=knob` 的做法(官方推荐 `seekbarhandlesize=0.6`)。
    static let scrubberKnobSize: CGFloat = 11
    /// 悬停 / 拖动时的播放头直径
    static let scrubberKnobSizeActive: CGFloat = 15
    /// 轨道底色
    static let scrubberTrackOpacity: Double = 0.28
    /// 已播放段
    static let scrubberPlayedOpacity: Double = 1.0
    /// 已缓冲段。比底色亮一档、比已播放段暗一档,层次靠这三个不透明度拉开。
    static let scrubberBufferedOpacity: Double = 0.55
    /// 悬停时间气泡距轨道的垂直距离
    static let scrubberTooltipOffset: CGFloat = 28

    /// 进度条上片头 / 片尾标记的不透明度。标记画在**已播放段之上**(播过片头还要看得见),
    /// 所以要不透明到能压住白色,又不至于盖掉底下的位置信息。
    static let scrubberMarkerOpacity: Double = 0.95
    /// 片尾起点竖条的宽度
    static let scrubberMarkerWidth: CGFloat = 2
    /// 片头标记带的最小宽度:片头很短时(几秒)也要看得见
    static let scrubberMarkerMinWidth: CGFloat = 3
    /// 续播时从服务端记录的位置往回退的秒数(接上前情,Infuse / Plex 的做法)
    static let resumeRewind: TimeInterval = 5
    /// 片头最后几秒不再显示「跳过片头」(见 `PlaybackMarkers.isInIntro`)
    static let skipIntroTailTolerance: TimeInterval = 1
    /// 「下一集」倒计时秒数
    static let upNextCountdown = 10
    /// 没有片尾标记时,结束前多少秒开始提示下一集(与倒计时等长:数完正好播完)
    static let upNextFallbackLead: TimeInterval = 10
    /// 缓冲进度 / 已缓存范围 / 统计信息的轮询间隔
    static let playerMonitorInterval: TimeInterval = 1
    /// 触控板横向双指滑动:每移动 1 pt 对应的秒数(300 pt 的一次长滑 ≈ 1 分钟)
    static let trackpadSeekSecondsPerPoint: Double = 0.2
    /// 横滑判定:横向累计位移要超过纵向的这么多倍才算「拖进度」,否则放行给系统
    static let trackpadHorizontalDominance: Double = 1.5
    /// 横滑判定:起判的最小横向累计位移(pt),滤掉手指搭上触控板时的抖动
    static let trackpadActivationDistance: Double = 6
    /// 跳过片头 / 下一集提示距窗口底部(控制栏可见时要让出控制栏)
    static let playerPromptBottomInset: CGFloat = 100

    // MARK: 分集面板(播放页右侧滑出的选集抽屉)

    /// 面板宽度。⛔ 不铺满:它要能和画面并存 —— 一边看一边挑下一集。
    static let episodePanelWidth: CGFloat = 380
    /// 面板里一行缩略图的宽度(16:9)。同时是图片请求的档位基准
    /// (`ImageSpec.maxWidth` 取它的两倍,视网膜屏才不糊)。
    static let episodeThumbnailWidth: CGFloat = 132
    /// 面板在材质上再压一层的黑色不透明度。视频亮度不可控,只靠玻璃的自适应
    /// 在亮画面上压不住,再叠一层固定的暗底才保证文字可读。
    static let episodePanelDimOpacity: Double = 0.55
    /// 收起把手的宽度。把手贴在抽屉左缘**外侧**(底下是视频,不是列表),
    /// 所以它不占 `episodePanelWidth` 的内容宽度。
    static let episodePanelCollapseHandleWidth: CGFloat = 22
    /// 收起把手的高度(竖直居中的一根短条,不是满高的边栏 —— 满高会像一条边框)
    static let episodePanelCollapseHandleHeight: CGFloat = 84

    // MARK: 海报网格

    /// 网格单元最小宽度
    static let posterMinWidth: CGFloat = 150
    /// 海报统一宽高比(宽 / 高)
    static let posterAspectRatio: Double = 2.0 / 3.0
    /// 横版(16:9)图片的宽高比(宽 / 高):「我的媒体」磁贴与「继续观看 / 下一集」卡片
    static let landscapeAspectRatio: Double = 16.0 / 9.0
    /// 「我的媒体」磁贴宽度
    static let libraryTileWidth: CGFloat = posterMinWidth * 1.2
    /// 「继续观看 / 下一集」横版卡片宽度
    static let landscapeCardWidth: CGFloat = posterMinWidth * 1.6
    /// 网格间距(= spacingL)
    static let gridSpacing: CGFloat = spacingL

    // MARK: 详情页 hero

    /// hero 背景的高度比例(按 `contentMaxWidth` 算高度,与 Emby 详情页同一口径)
    static let heroAspectRatio: Double = 9.0 / 16.0
    /// hero 背景的模糊半径。百度只有竖版海报、没有 Emby 那种宽幅 backdrop,
    /// 直接把竖图铺满会很难看 —— 放大 + 模糊当背景,海报本身另画一份清晰的。
    static let heroBackdropBlur: CGFloat = 24
    /// 模糊会把边缘吃虚,放大一点把边补满
    static let heroBackdropScale: CGFloat = 1.2
    /// hero 背景的暗化程度(压暗之后压在上面的标题才读得清)
    static let heroBackdropDimOpacity: Double = 0.45
    /// hero 里标题区向上压进背景的比例
    static let heroOverlapRatio: CGFloat = 0.45

    // MARK: 首页 hero(`HomeHero`)

    /// **图片区**高度 = 宽度 × 这个比例,再夹到上下限(hero 总高再加 `homeHeroFadeBand`)。
    /// 2026-10-15 用户嫌 0.5 / 上限 720 占版面太大,压到 0.32 / 500:1728pt 宽的窗口里
    /// hero 总高约 570,首屏能露出「我的媒体」和「继续观看」两行。清晰图跟着变窄
    /// (宽 = 高 × 16:9),左边多出来的由模糊底图接住,不影响比例
    static let homeHeroHeightRatio: CGFloat = 0.32
    static let homeHeroMinHeight: CGFloat = 300
    static let homeHeroMaxHeight: CGFloat = 500
    /// 背景图请求的宽度档位(像素;Emby 按它缩放,必带,API_CONTRACT.md 3.3)
    static let homeHeroImageMaxWidth: CGFloat = 1920
    /// backdrop 的标准宽高比(Emby / TMDB 的背景图都是 16:9)。清晰的那张按图片区高度
    /// **完整**摆放、靠右,宽度 = 高 × 这个比例,⛔ 不铺满整宽:1280×720 的图铺到 1728pt 宽
    /// 要放大 1.35 倍、上下裁掉四分之一,看着就是「被放大、只看到一部分」(2026-10-15 实测像素)
    static let homeHeroImageAspect: CGFloat = 16.0 / 9.0
    /// 清晰图左边剩下的地方,由**同一张图**整宽铺满后重度模糊填上(同一 spec,命中缓存,不多发请求)。
    /// ⛔ 别调轻:铺的是整张图放大后的样子,模糊一轻就看得出和右边是同一批人物
    /// (2026-10-15 试过 28 / 14,以及镜像、拉伸边缘两种接边,用户决定退回 60)
    static let homeHeroAmbientBlur: CGFloat = 60
    /// 图片区下方的过渡带:模糊底图在这里柔和地渐变到窗口底色,货架从它下面接上。
    /// ⛔ 不在图片区底边硬切成白色(太生硬),也 ⛔ 不让清晰图直接线性淡出成白雾(第一版的问题)
    static let homeHeroFadeBand: CGFloat = 72
    /// 左侧文字区压暗:最左端黑色的不透明度
    static let homeHeroSideScrimOpacity: Double = 0.55
    /// 左侧压暗渐变到透明的位置(占宽度的比例)
    static let homeHeroSideScrimEnd: Double = 0.6
    /// 标题左边那张竖版小封面的宽度(2:3)。与海报卡片同宽,图片档位相同 → 直接命中卡片的图片缓存
    static let homeHeroPosterWidth: CGFloat = posterMinWidth
    /// 简介的最大宽度(两行)
    static let homeHeroOverviewMaxWidth: CGFloat = 560
    /// Logo 的最大尺寸。Logo 只是装饰(文字标题始终在它下面,`HomeHero.titleView`),
    /// 所以比单独当标题时小一号
    static let homeHeroLogoMaxWidth: CGFloat = 280
    static let homeHeroLogoMaxHeight: CGFloat = 72
    /// 续播进度条宽度
    static let homeHeroProgressWidth: CGFloat = 220
    /// backdrop 取不到时,模糊海报底图的模糊半径。比详情页的 `heroBackdropBlur` 重得多:
    /// 一张 300 宽的竖图被拉到整窗宽,轻模糊下看得出放大的五官(2026-10-15 截图),
    /// 这里只要它当「色调」,清晰的那张由小封面负责
    static let homeHeroFallbackBlur: CGFloat = 80
    /// 轮播分页圆点的直径(`HomeHeroCarousel`)。比系统 `PageControl` 的小一号,
    /// 它压在图上、只是位置提示,不该抢文字区的注意力
    static let heroDotSize: CGFloat = 7

    // MARK: 批量标记分集(`SeasonPlayedPickerSheet`,API_CONTRACT.md 5.8)

    /// 面板宽度。与 `DanmakuPickerSheet` / `PlayerMarkersEditor` 同一量级:
    /// 一行放得下「集号. 集名」+ 已看标记,又不至于宽得像另一个窗口。
    static let playedPickerWidth: CGFloat = 520
    /// 分集清单的高度上限:集多时滚动。
    static let playedPickerListMaxHeight: CGFloat = 420
    /// 清单里一行的高度(复选框 + 一行文字)。
    ///
    /// 高度是**按行数算出来的**(`SeasonPlayedPickerSheet.listHeight`),不是把 `List`
    /// 丢进弹性容器:那样集少时下方空一大片、集多时又按容器高度硬裁。
    static let playedPickerRowHeight: CGFloat = 24

    // MARK: 分集货架滚动条

    /// 滑块厚度(与系统覆盖式滚动条同量级;不画轨道,只有这一条)
    static let shelfScrubberThumbHeight: CGFloat = 8
    /// 滑块最小宽度。集数极多时按比例算出的滑块会细如发丝,留一个能点中的下限
    static let shelfScrubberThumbMinWidth: CGFloat = 28
    /// 滚动条的可点击高度(含上下留白,比可见的滑块高,拖起来不费劲)
    static let shelfScrubberHitHeight: CGFloat = 20
    /// 滑块不透明度(贴近系统覆盖式滚动条的浅灰)
    static let shelfScrubberThumbOpacity: Double = 0.3
    /// 指针压在滚动条上 / 拖动时的不透明度(深一档,和系统一致)
    static let shelfScrubberThumbOpacityHover: Double = 0.55
    /// 停止滚动后滚动条淡出的延迟。与系统覆盖式滚动条一样:滚动时在,停下后隐去
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
