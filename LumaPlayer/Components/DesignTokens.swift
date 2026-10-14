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
/// 工具栏声明在栈上(各页共用);搜索框(提交式,回车才搜)挂在栈根和每个 push 页上 —— 挂在栈外面
/// macOS 27 上不出现。详情页头部只有返回与搜索:不放服务器切换器(切换会清掉导航栈)、
/// 不铺工具栏背景色(hero 图透到标题栏下;原生全屏下那条栏去不掉,`PITFALLS.md` Q37)。
/// 服务器切换在内容页工具栏菜单里,管理在设置窗口「服务器」页。
///
/// **加载态**:首屏无内容时用灰色骨架(`Skeleton*`)照真实布局占位;刷新时保留旧内容,
/// 失败也保留;「在不在加载」只看工具栏刷新图标转圈;加载中整页不可点。
/// 加载成功但为空的首页行整行不显示;「我的媒体」的加载 / 失败态必须显示。
///
/// **Liquid Glass**:只用于临时、可操作、浮在内容上的元素 —— 播完卡片 / 下一集提示、
/// 服务器切换器、字幕 / 音轨 / 倍速浮层、屏显提示胶囊、详情页播放主按钮(可带轻 tint)。
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
