import Foundation
import Observation
import os

/// 弹幕外观偏好(全 App 一份,UserDefaults)。
///
/// 与 `SubtitleStyle` 同一套做法:值类型 + `clamped` 兜住越界值,
/// 由 `DanmakuSettingsStore` 存取。不含任何凭据(AppId / AppSecret 在凭据文件里)。
struct DanmakuDisplaySettings: Codable, Sendable, Equatable {
    /// 打开播放页时是否自动加载并显示弹幕
    var isEnabled = true
    /// 不透明度 0.2 - 1
    var opacity = 0.85
    /// 字号(pt,按 1080 高的画面计,渲染时按窗口高度等比缩放)
    var fontSize = 25.0
    /// 一条滚动弹幕横穿画面的时长(秒),越小越快
    var scrollDuration = 8.0
    /// 弹幕可占的画面高度比例(0.25 / 0.5 / 0.75 / 1)
    var displayArea = 0.75
    var showsScroll = true
    var showsTop = true
    var showsBottom = true
    /// 用文件指纹(前 16 MiB 的 MD5)提高 `/match` 的准确度。
    ///
    /// 代价是起播时对**直连流**补一次 `Range` 请求拉 16 MiB(`DanmakuFingerprint`)。
    /// 默认开:对 Emby 直连流来说这 16 MiB 正是播放器接下来要读的字节,而指纹是
    /// 「同一份文件」唯一的硬证据(`DANMAKU.md` §3)。限速 / 按流量计费的服务器
    /// 可以在这里关掉,关掉后退回文件名匹配。
    var usesFileFingerprint = true

    static let `default` = DanmakuDisplaySettings()

    static let opacityRange = 0.2...1.0
    static let fontSizeRange = 16.0...40.0
    static let scrollDurationRange = 4.0...14.0
    static let displayAreaChoices = [0.25, 0.5, 0.75, 1.0]

    var clamped: DanmakuDisplaySettings {
        var copy = self
        copy.opacity = Self.clamp(opacity, Self.opacityRange, fallback: Self.default.opacity)
        copy.fontSize = Self.clamp(fontSize, Self.fontSizeRange, fallback: Self.default.fontSize)
        copy.scrollDuration = Self.clamp(
            scrollDuration, Self.scrollDurationRange, fallback: Self.default.scrollDuration)
        copy.displayArea = Self.clamp(displayArea, 0.1...1, fallback: Self.default.displayArea)
        return copy
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

/// 弹幕外观偏好的存取。挂在 `AppContainer` 上:设置窗口与播放窗口共用同一实例,
/// 播放中改设置即时生效(理由同 `SubtitleStyleStore`)。
@MainActor
@Observable
final class DanmakuSettingsStore {
    var settings: DanmakuDisplaySettings {
        didSet {
            let clamped = settings.clamped
            if clamped != settings { settings = clamped; return }
            guard settings != oldValue else { return }
            persist()
        }
    }

    static let defaultsKey = "player.danmakuSettings"
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "danmaku")

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    func reset() {
        settings = .default
    }

    private static func load(from defaults: UserDefaults) -> DanmakuDisplaySettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return .default }
        do {
            return try JSONDecoder().decode(DanmakuDisplaySettings.self, from: data).clamped
        } catch {
            // 偏好损坏只影响外观,不挡播放;记下原因,下次改设置会覆盖坏数据
            logger.error("弹幕偏好解码失败,使用默认值: \(String(describing: error), privacy: .public)")
            return .default
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("弹幕偏好保存失败: \(String(describing: error), privacy: .public)")
        }
    }
}
