import Foundation

/// 播放偏好:起播默认值(倍速 / 跳转步长 / 音量 / 字幕)与播放期行为开关。
///
/// 全 App 一份、存 UserDefaults、全部服务器共用 —— 与 `SubtitleStyleStore` 同一个理由:
/// 设置窗口改、播放窗口读,两边必须是同一个实例,改完下一集 / 新建播放器就生效。
/// 挂在 `AppContainer` 上而不是 `PlayerViewModel` 里:换一集就新建一个 ViewModel,
/// 记在里面只能在本次播放内活下来。
///
/// ⛔ 偏好是从 UserDefaults 读回来的,不能假设没被手改过 —— 读进来一律夹回合法范围
/// (要求就是「设置页里能改,且改完留得住」)。
@MainActor
@Observable
final class PlaybackPreferences {

    // MARK: - 起播默认值

    /// 起播倍速。本次运行里为这部剧调过倍速时以那个值为准
    /// (`PlaybackSpeedStore`,P0-3),没调过才用它。
    var defaultSpeed: Double {
        didSet { persist(defaultSpeed, Key.defaultSpeed) }
    }
    /// 前后跳转步长(秒)。必须是 `Metrics.seekStepOptions` 之一。
    var seekStep: Double {
        didSet { persist(seekStep, Key.seekStep) }
    }
    /// 起播音量(0–100)。每次新建播放器套用 —— 转码 seek 重新起流也是新播放器。
    var defaultVolume: Double {
        didSet { persist(defaultVolume, Key.defaultVolume) }
    }
    /// 起播时对字幕轨的处理(见 `SubtitleMode`)
    var subtitleMode: SubtitleMode {
        didSet { persist(subtitleMode.rawValue, Key.subtitleMode) }
    }

    // MARK: - 播放期行为

    /// 进入片头区间时自动跳过。默认关:和 Plex / Infuse 一样先给按钮,
    /// 标记不准时自动跳会直接吃掉正片开头。
    var autoSkipIntro: Bool {
        didSet { persist(autoSkipIntro, Key.autoSkipIntro) }
    }
    /// 片尾提示出现后倒计时自动播下一集。默认开(Plex / Netflix 的默认值),可在提示上取消。
    var autoPlayNext: Bool {
        didSet { persist(autoPlayNext, Key.autoPlayNext) }
    }
    /// 播放窗口置顶(`NSWindow.level = .floating`)
    var floatsOnTop: Bool {
        didSet { persist(floatsOnTop, Key.floatsOnTop) }
    }

    // MARK: - 色彩渲染

    /// 渲染后端策略。默认 `automatic`:只有 Dolby Vision 片源用 gpu-next(libplacebo),
    /// 其余用省电的 legacy `gpu`(判据与时机见 `MPVRenderBackendPolicy`)。
    /// 「始终 gpu-next / 始终旧渲染器」是兜底:gpu-next 走的是上游**未合并的 draft PR**,
    /// 自动判断或 gpu-next 本身让某些片源出问题时,用户能自己固定下来。
    /// 详见 docs/MPV_INTEGRATION.md §0、§3.3。
    ///
    /// 起播时读一次(建 `MPVPlayer` 时),**下一次起播才生效**。
    var renderBackendPolicy: MPVRenderBackendPolicy {
        didSet { persist(renderBackendPolicy.rawValue, Key.renderBackendPolicy) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultSpeed = Self.speed(from: defaults)
        self.seekStep = Self.seekStep(from: defaults)
        self.defaultVolume = Self.volume(from: defaults)
        self.subtitleMode = Self.mode(from: defaults)
        self.autoSkipIntro = defaults.bool(forKey: Key.autoSkipIntro)
        self.autoPlayNext = defaults.object(forKey: Key.autoPlayNext) as? Bool ?? true
        self.floatsOnTop = defaults.bool(forKey: Key.floatsOnTop)
        self.renderBackendPolicy = Self.renderBackendPolicy(from: defaults)
    }

    /// 全部回到出厂值。设置页「恢复默认」用。
    func reset() {
        defaultSpeed = Self.defaultSpeed
        seekStep = Metrics.seekStep
        defaultVolume = Metrics.defaultVolume
        subtitleMode = Self.defaultSubtitleMode
        autoSkipIntro = false
        autoPlayNext = true
        floatsOnTop = false
        renderBackendPolicy = Self.defaultRenderBackendPolicy
    }

    /// 是否有任何一项偏离默认(设置页「恢复默认」按钮的禁用判据)
    var isDefault: Bool {
        defaultSpeed == Self.defaultSpeed && seekStep == Metrics.seekStep
            && defaultVolume == Metrics.defaultVolume && subtitleMode == Self.defaultSubtitleMode
            && !autoSkipIntro && autoPlayNext && !floatsOnTop
            && renderBackendPolicy == Self.defaultRenderBackendPolicy
    }

    // MARK: - 默认值与夹取

    static let defaultSpeed: Double = 1
    static let defaultSubtitleMode: SubtitleMode = .smart
    static let defaultRenderBackendPolicy: MPVRenderBackendPolicy = .automatic

    // MARK: - 持久化

    /// UserDefaults key。三个开关沿用开发期就在用的键名,老版本存下的值继续有效。
    enum Key {
        static let defaultSpeed = "player.defaultSpeed"
        static let seekStep = "player.seekStep"
        static let defaultVolume = "player.defaultVolume"
        static let subtitleMode = "player.subtitleMode"
        static let autoSkipIntro = "player.autoSkipIntro"
        static let autoPlayNext = "player.autoPlayNext"
        static let floatsOnTop = "player.floatsOnTop"
        static let renderBackendPolicy = "player.renderBackendPolicy"
        /// 旧版的 Bool 开关「杜比视界 / HDR 兼容渲染」,只读不写(迁移见 `renderBackendPolicy(from:)`)
        static let legacyPreferGPUNextRenderer = "player.preferGPUNextRenderer"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private func persist(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: - 读回(夹取)

    /// 没存过、或存的不是数字时用默认;存过就夹到倍速区间。
    ///
    /// ⛔ 不用 `double(forKey:)` 判「有没有存过」:它读非数字一律返回 0,
    /// 存了个字符串会被当成「起播 0.25×」。
    private static func speed(from defaults: UserDefaults) -> Double {
        guard let stored = defaults.object(forKey: Key.defaultSpeed) as? NSNumber else {
            return defaultSpeed
        }
        return Metrics.clampedSpeed(stored.doubleValue)
    }

    /// 步长只认 `Metrics.seekStepOptions` 里的值:手改成 7 秒这种,
    /// 与其照用(菜单文案、系统「正在播放」的跳转间隔都会跟着怪),不如退回默认。
    private static func seekStep(from defaults: UserDefaults) -> Double {
        guard let stored = defaults.object(forKey: Key.seekStep) as? NSNumber else {
            return Metrics.seekStep
        }
        let value = stored.doubleValue
        return Metrics.seekStepOptions.first(where: { $0 == value }) ?? Metrics.seekStep
    }

    private static func volume(from defaults: UserDefaults) -> Double {
        guard let stored = defaults.object(forKey: Key.defaultVolume) as? NSNumber else {
            return Metrics.defaultVolume
        }
        let value = stored.doubleValue
        guard value.isFinite else { return Metrics.defaultVolume }
        return min(max(value, Metrics.volumeRange.lowerBound), Metrics.volumeRange.upperBound)
    }

    /// 存了不认识的模式名(以后删档位 / 手改)时退回默认,不整份偏好判坏。
    private static func mode(from defaults: UserDefaults) -> SubtitleMode {
        guard let raw = defaults.string(forKey: Key.subtitleMode) else { return defaultSubtitleMode }
        return SubtitleMode(rawValue: raw) ?? defaultSubtitleMode
    }

    /// 新键优先;没存过新键时看旧版 Bool 开关:显式关过 = 用户要的是 legacy,保留;
    /// 开着(含「恢复默认」写下的 true)= 当初只是为了 DV 正确,归到 `automatic`。
    private static func renderBackendPolicy(from defaults: UserDefaults) -> MPVRenderBackendPolicy {
        if let raw = defaults.string(forKey: Key.renderBackendPolicy) {
            return MPVRenderBackendPolicy(rawValue: raw) ?? defaultRenderBackendPolicy
        }
        // ⛔ 不用 bool(forKey:):没存过时会读成 false,把「没存过」误当成「关过」。
        if defaults.object(forKey: Key.legacyPreferGPUNextRenderer) as? Bool == false {
            return .legacy
        }
        return defaultRenderBackendPolicy
    }
}
