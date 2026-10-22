import Foundation

/// 播放偏好:起播默认值与播放期行为开关。全 App 一份、存 UserDefaults、所有服务器共用。
///
/// 挂在 `AppContainer` 上(设置窗口改、播放窗口读须同一实例);⛔ 不放进 `PlayerViewModel`,
/// 它每集新建。读回时一律夹回合法范围,不假设 UserDefaults 没被手改过。
@MainActor
@Observable
final class PlaybackPreferences {

    // MARK: - 起播默认值

    /// 本次运行里为这部剧调过倍速(`PlaybackSpeedStore`)时以那个为准
    var defaultSpeed: Double {
        didSet { persist(defaultSpeed, Key.defaultSpeed) }
    }
    /// 秒,必须是 `Metrics.seekStepOptions` 之一
    var seekStep: Double {
        didSet { persist(seekStep, Key.seekStep) }
    }
    /// 0–100。每次新建播放器套用(转码 seek 重新起流也是新播放器)
    var defaultVolume: Double {
        didSet { persist(defaultVolume, Key.defaultVolume) }
    }
    var subtitleMode: SubtitleMode {
        didSet { persist(subtitleMode.rawValue, Key.subtitleMode) }
    }

    // MARK: - 播放期行为

    /// 默认关:标记不准时自动跳会吃掉正片开头,先给按钮
    var autoSkipIntro: Bool {
        didSet { persist(autoSkipIntro, Key.autoSkipIntro) }
    }
    /// 片尾提示后倒计时自动播下一集,默认开
    var autoPlayNext: Bool {
        didSet { persist(autoPlayNext, Key.autoPlayNext) }
    }
    /// `NSWindow.level = .floating`
    var floatsOnTop: Bool {
        didSet { persist(floatsOnTop, Key.floatsOnTop) }
    }

    // MARK: - 色彩渲染

    /// 默认 `automatic`(见 `MPVRenderBackendPolicy`);固定档位是兜底 —— gpu-next 来自上游
    /// 未合并的 draft PR,出问题时用户可自己固定(MPV_INTEGRATION.md §0、§3.3)。
    /// 建 `MPVPlayer` 时读,下一次起播才生效。
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

    /// 设置页「恢复默认」按钮的禁用判据
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

    /// ⛔ 不改键名:已存的值要继续有效。
    enum Key {
        static let defaultSpeed = "player.defaultSpeed"
        static let seekStep = "player.seekStep"
        static let defaultVolume = "player.defaultVolume"
        static let subtitleMode = "player.subtitleMode"
        static let autoSkipIntro = "player.autoSkipIntro"
        static let autoPlayNext = "player.autoPlayNext"
        static let floatsOnTop = "player.floatsOnTop"
        static let renderBackendPolicy = "player.renderBackendPolicy"
        /// 旧 Bool 开关,只读不写(迁移见 `renderBackendPolicy(from:)`)
        static let legacyPreferGPUNextRenderer = "player.preferGPUNextRenderer"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private func persist(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: - 读回(夹取)

    /// ⛔ 不用 `double(forKey:)`:非数字读成 0,会被夹成起播 0.25×。
    private static func speed(from defaults: UserDefaults) -> Double {
        guard let stored = defaults.object(forKey: Key.defaultSpeed) as? NSNumber else {
            return defaultSpeed
        }
        return Metrics.clampedSpeed(stored.doubleValue)
    }

    /// 不在 `Metrics.seekStepOptions` 里的值退回默认(菜单文案、系统「正在播放」跳转间隔都依赖它)。
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

    /// 不认识的模式名退回默认。
    private static func mode(from defaults: UserDefaults) -> SubtitleMode {
        guard let raw = defaults.string(forKey: Key.subtitleMode) else { return defaultSubtitleMode }
        return SubtitleMode(rawValue: raw) ?? defaultSubtitleMode
    }

    /// 新键优先;否则看旧 Bool 开关:显式 false = 用户要 legacy;true 归到 `automatic`。
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
