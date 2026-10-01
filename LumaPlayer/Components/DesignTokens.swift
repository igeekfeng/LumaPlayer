import CoreGraphics
import Foundation

/// 设计 token(UI_DESIGN.md 2.1,硬约束):所有视图必须引用本文件数值,
/// ⛔ 禁止在视图代码里写间距 / 圆角 / 时长字面量。
/// 字号统一用系统语义字体,唯一例外是播放器时间标签的
/// `.monospacedDigit()`(等宽数字,不改字号)。

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

    /// 主窗口内容列(首页 / 媒体库 / 搜索)是主区域:默认宽度要压过详情列。
    /// 不钉宽度的话它会按「边栏」语义拿到 220 出头的默认宽度,首页被挤成一条窄带。
    static let contentColumnMinWidth: CGFloat = 520
    static let contentColumnIdealWidth: CGFloat = 840
    /// 主窗口详情列:次要区域,但要放得下 hero、简介与剧集列表
    static let detailColumnMinWidth: CGFloat = 380
    static let detailColumnIdealWidth: CGFloat = 440

    // MARK: 设置窗口

    /// 设置窗口的尺寸(「服务器」标签页要放得下一行的名称 / 地址 / 账户 / 版本)
    static let settingsWindowWidth: CGFloat = 560
    static let settingsWindowHeight: CGFloat = 420

    // MARK: 播放器控制栏

    /// 底部控制栏高度(含内边距)
    static let controlBarHeight: CGFloat = 56
    /// 控制栏距窗口底部
    static let controlBarBottomInset: CGFloat = 12
    /// 无交互后控制栏淡出
    static let autoHideDelay: TimeInterval = 3
    /// 恢复播放后额外等待(避免刚恢复就隐藏)
    static let autoHideResumeDelay: TimeInterval = 5
    /// 方向键单次 seek
    ///
    /// 转码模式下不是 mpv seek,而是停流 + StartTimeTicks 重新起流
    /// (API_CONTRACT.md 4.5);token 值相同,行为由 PlayerViewModel 分派。
    static let seekStep: TimeInterval = 10
    /// Shift+方向键单次 seek
    static let seekStepLarge: TimeInterval = 30
    /// 音量单次增减(0–100)
    static let volumeStep: Double = 5
    /// 倍速区间:与 `MPVPlayer.setSpeed` 的夹取一致(超出这个范围音频严重失真)
    static let speedRange: ClosedRange<Double> = 0.25...4
    /// 倍速滑块与浮层 ± 按钮的步长(连续调节,不按档位跳)
    static let speedStep: Double = 0.05
    /// `[` `]` 的步长:比滑块粗一档,一次按键要有明显变化
    static let speedKeyStep: Double = 0.1
    /// 连续调倍速时的上报合并窗口(见 `PlayerViewModel.scheduleRateChangeReport`)
    static let speedReportDelay: TimeInterval = 0.5
    /// 播放器图标按钮的点击区域边长(控制栏与菜单按钮一致,避免图标宽窄不一导致跳动)
    static let playerButtonSize: CGFloat = 32
    /// 屏显提示(OSD,如「1.25×」「字幕:中文」)停留时长
    static let osdDuration: TimeInterval = 1.2
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
    /// 播放器底部控制栏(与 UI_DESIGN.md 4.3 示例一致)
    static let glassBar: CGFloat = 18
}
