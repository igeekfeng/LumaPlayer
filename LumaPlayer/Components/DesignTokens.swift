import CoreGraphics
import Foundation

/// 设计 token(硬约束):所有视图引用本文件数值,⛔ 视图代码里不写间距 / 圆角 / 时长字面量。

enum Metrics {
    // MARK: 间距

    static let spacingXXS: CGFloat = 2
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let contentMaxWidth: CGFloat = 680

    // MARK: 表单

    static let onboardingFormWidth: CGFloat = 460
    static let onboardingPrimaryButtonMinWidth: CGFloat = 64

    static let serverRowIconSize: CGFloat = 36
    static let onboardingLogoSize: CGFloat = 52

    // MARK: 主窗口

    static let mainWindowWidth: CGFloat = 1280
    static let mainWindowHeight: CGFloat = 800

    // MARK: 主窗口浮动顶栏

    static let chromeBarHeight: CGFloat = 52
    static let chromeBarLeading: CGFloat = 72
    static let chromeBackHitSize: CGFloat = 28
    static let chromeBackIdleOpacity: Double = 0.75
    static let chromeSearchWidth: CGFloat = 180
    static let chromeSearchHeight: CGFloat = 32
    static let chromeSourceMarkSize: CGFloat = 22
    static let chromeScrimSolidFraction: Double = 0.55
    static let chromeHeroScrimOpacity: Double = 0.35
    static let chromeLoadingLineHeight: CGFloat = 2
    static let chromeLoadingLineSegmentFraction: CGFloat = 0.25
    static let chromeLoadingLinePeriod: TimeInterval = 1.2
    static let chromeLoadingLineStaticOpacity: Double = 0.6

    // MARK: 设置窗口

    static let settingsWindowWidth: CGFloat = 560
    static let settingsWindowHeight: CGFloat = 420
    static let settingsValueWidth: CGFloat = 64
    static let colorSwatchSize: CGFloat = 22

    // MARK: 播放器控制栏

    static let controlBarSideInset: CGFloat = 32
    static let controlBarBottomInset: CGFloat = 16
    static let controlBarTopInset: CGFloat = 20
    static let controlBarScrimOpacity: Double = 0.55
    static let controlBarScrimStart: Double = 0.05
    static let autoHideDelay: TimeInterval = 2
    static let autoHidePointerExitDelay: TimeInterval = 0.3
    static let autoHideResumeDelay: TimeInterval = 5
    static let seekStep: TimeInterval = 10
    static let seekStepLarge: TimeInterval = 30
    static let seekStepOptions: [TimeInterval] = [5, 10, 15, 30]
    static let seekRestartMergeDelay: TimeInterval = 0.25
    static let seekRepeatMaxMultiple: Int = 5
    static let seekRepeatResetDelay: TimeInterval = 1.2
    static let volumeStep: Double = 5
    static let volumeRange: ClosedRange<Double> = 0...100
    static let defaultVolume: Double = 100
    static let speedRange: ClosedRange<Double> = 0.25...4
    static let speedStep: Double = 0.05
    static let speedKeyStep: Double = 0.1
    static let speedReportDelay: TimeInterval = 0.5

    static func clampedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let clamped = min(max(value, speedRange.lowerBound), speedRange.upperBound)
        return (clamped * 100).rounded() / 100
    }

    static let subtitleDelayRange: ClosedRange<Double> = -60...60
    static let subtitleDelayStep: Double = 0.1
    static let subtitleDelayLargeStep: Double = 1
    static let audioDelayRange: ClosedRange<Double> = -10...10
    static let audioDelayStep: Double = 0.1
    static let audioDelayLargeStep: Double = 1
    static let playerButtonSize: CGFloat = 36
    static let playerButtonHoverOpacity: Double = 0.15
    static let playerButtonActiveOpacity: Double = 0.22

    // MARK: 控制栏弹出面板

    static let playerPanelWidth: CGFloat = 272
    static let playerPanelRowHeight: CGFloat = 36
    static let playerPanelChipHeight: CGFloat = 32
    static let playerPanelStepButtonWidth: CGFloat = 40
    static let playerPanelTileHeight: CGFloat = 48
    static let playerPanelMaxVisibleRows = 7
    static let playerPanelEdgeInset: CGFloat = 16
    static let playerPanelDimOpacity: Double = 0.45
    static let playerPanelItemFillOpacity: Double = 0.07
    static let playerPanelItemHoverOpacity: Double = 0.14
    static let playerPanelItemPressedOpacity: Double = 0.2
    static let playerPanelRowSelectedOpacity: Double = 0.1
    static let playerPanelSeparatorThickness: CGFloat = 0.5
    static let osdDuration: TimeInterval = 1.2

    // MARK: 进度条

    static let scrubberTrackHeight: CGFloat = 4
    static let scrubberTrackHeightActive: CGFloat = 7
    static let scrubberKnobSize: CGFloat = 11
    static let scrubberKnobSizeActive: CGFloat = 15
    static let scrubberTrackOpacity: Double = 0.28
    static let scrubberPlayedOpacity: Double = 1.0
    static let scrubberBufferedOpacity: Double = 0.55
    static let scrubberTooltipOffset: CGFloat = 28
    static let scrubberMarkerOpacity: Double = 0.95
    static let scrubberMarkerWidth: CGFloat = 2
    static let scrubberMarkerMinWidth: CGFloat = 3
    static let scrubberChapterTickWidth: CGFloat = 1
    static let scrubberChapterTickOpacity: Double = 0.55
    static let resumeRewind: TimeInterval = 5
    static let skipIntroTailTolerance: TimeInterval = 1
    /// 自动换集的提前量(秒):切换点(片尾标记或片尾)前这么久开始提示并走完倒计时。
    static let upNextLead: TimeInterval = 10
    static let playerMonitorInterval: TimeInterval = 1
    static let trackpadSeekSecondsPerPoint: Double = 0.2
    static let trackpadHorizontalDominance: Double = 1.5
    static let trackpadActivationDistance: Double = 6
    static let playerPromptBottomInset: CGFloat = 100

    // MARK: 分集面板

    static let episodePanelWidth: CGFloat = 380
    static let episodeThumbnailWidth: CGFloat = 132
    static let episodePanelDimOpacity: Double = 0.55
    static let episodePanelCollapseHandleWidth: CGFloat = 22
    static let episodePanelCollapseHandleHeight: CGFloat = 84

    // MARK: 海报网格

    static let posterMinWidth: CGFloat = 150
    static let posterAspectRatio: Double = 2.0 / 3.0
    static let landscapeAspectRatio: Double = 16.0 / 9.0
    static let libraryTileWidth: CGFloat = posterMinWidth * 1.2
    static let landscapeCardWidth: CGFloat = posterMinWidth * 1.6
    static let gridSpacing: CGFloat = spacingL
    static let shelfHeaderMinHeight: CGFloat = 24
    static let posterCardTextHeight: CGFloat = 50
    static let landscapeCardTextHeight: CGFloat = 33
    static let libraryTileTextHeight: CGFloat = 16

    // MARK: 详情页 hero

    static let heroAspectRatio: Double = 9.0 / 16.0
    static let heroBackdropBlur: CGFloat = 24
    static let heroBackdropScale: CGFloat = 1.2
    static let heroBackdropDimOpacity: Double = 0.45
    static let heroOverlapRatio: CGFloat = 0.45

    // MARK: 首页 hero

    static let homeHeroHeightRatio: CGFloat = 0.32
    static let homeHeroMinHeight: CGFloat = 300
    static let homeHeroMaxHeight: CGFloat = 500
    static let homeHeroImageMaxWidth: CGFloat = 1920
    static let homeHeroImageAspect: CGFloat = 16.0 / 9.0
    static let homeHeroAmbientBlur: CGFloat = 60
    static let homeHeroFadeBand: CGFloat = 72
    static let homeHeroSideScrimOpacity: Double = 0.55
    static let homeHeroSideScrimEnd: Double = 0.6
    static let homeHeroPosterWidth: CGFloat = posterMinWidth
    static let homeHeroOverviewMaxWidth: CGFloat = 560
    static let homeHeroLogoMaxWidth: CGFloat = 280
    static let homeHeroLogoMaxHeight: CGFloat = 72
    static let homeHeroProgressWidth: CGFloat = 220
    static let homeHeroFallbackBlur: CGFloat = 80
    static let heroDotSize: CGFloat = 7

    // MARK: 播放按钮

    // 详情页操作按钮:同一高度,主按钮用系统液态玻璃,背景填充表示观看比例
    static let detailActionHeight: CGFloat = 42
    static let detailPlayButtonWidth: CGFloat = 224
    static let detailPlayFontSize: CGFloat = 16
    static let detailActionSymbolSize: CGFloat = 17
    static let detailPlayProgressOpacity: Double = 0.08

    // 详情页底部的次要出口(TMDB 标识 / 图片墙):不抢操作条,标识只按文字大小
    static let detailSecondaryMarkHeight: CGFloat = 13

    // 标题 Logo 替换文字标题时的显示上限(与 Emby 详情页 DetailTitle 同口径)
    static let detailTitleLogoMaxWidth: CGFloat = contentMaxWidth / 2
    static let detailTitleLogoMaxHeight: CGFloat = posterMinWidth / 2

    // 卡片上的紧凑按钮:进度作为外圈圆弧,常显无悬停特效
    static let progressPlayBadgeSize: CGFloat = 40
    static let progressPlayRingWidth: CGFloat = 3
    static let progressPlayRingTrackOpacity: Double = 0.28
    static let progressPlayFillOpacity: Double = 0.55
    static let progressPlayShadowOpacity: Double = 0.3
    static let progressPlaySymbolRatio: CGFloat = 0.34
    static let progressPlaySymbolOffsetRatio: CGFloat = 0.02

    // MARK: 批量标记分集

    static let playedPickerWidth: CGFloat = 520
    static let playedPickerListMaxHeight: CGFloat = 420
    static let playedPickerRowHeight: CGFloat = 24

    // MARK: 分集货架滚动条

    static let shelfScrubberThumbHeight: CGFloat = 8
    static let shelfScrubberThumbMinWidth: CGFloat = 28
    static let shelfScrubberHitHeight: CGFloat = 20
    static let shelfScrubberThumbOpacity: Double = 0.3
    static let shelfScrubberThumbOpacityHover: Double = 0.55
    static let shelfScrubberHideDelay: TimeInterval = 1.0

    // MARK: 动画时长

    static let animationFast: TimeInterval = 0.15
    static let animationStandard: TimeInterval = 0.25
    static let animationSlow: TimeInterval = 0.4
}

enum Radius {
    static let card: CGFloat = 8
    static let panel: CGFloat = 12
    static let playerPanel: CGFloat = 16
    static let playerPanelItem: CGFloat = 8
    static let tag: CGFloat = 4
}
