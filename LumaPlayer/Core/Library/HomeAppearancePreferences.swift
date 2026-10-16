import Foundation

/// 首页顶部 hero 的显示偏好(全 App 一份、存 UserDefaults、全部服务器共用)。
///
/// ⛔ 目前只有一项 —— `showsHeroRecommendations`:首页顶部要不要**随机推荐**轮播。
///
/// ## 为什么要这个开关
///
/// hero 的数据源是 `GET /Users/{UserId}/Items?SortBy=Random`
/// (`ServerConnection.recommendations`)。它在真实服务器上表现很好,
/// 但**推荐 = 用户没看过的随机一项**,同一个人每次看到的东西没有内在关系,
/// 有人就是不想在首屏看到随机的东西。给一个开关,而不是把 hero 写死。
///
/// ## 关闭时的行为
///
/// **整个 hero 都不显示**,首页直接从「我的媒体」开始 —— 用户主动关掉的,
/// ⛔ 不该又从「继续观看 / 各库最新」里找一张顶上来当替补。
/// (退路选择本身是对的:推荐**请求失败**时 hero 仍要退回一张,那是容错,
/// 不是用户的选择。见 `HomeViewModel.heroPick` 与 `HomeFeatureTests`。)
///
/// 关闭时**不发那个请求**(少一次网络往返,也少一批 1920 宽的背景图),
/// 由 `HomeViewModel.load` 判断。
@MainActor
@Observable
final class HomeAppearancePreferences {

    // MARK: - 偏好项

    /// 首页顶部是否显示随机推荐的 hero 轮播。
    ///
    /// 默认 `true`:与引入这个 hero 时(2026-10-15)的行为一致,
    /// 老用户升级后不会突然少掉首屏那块。
    var showsHeroRecommendations: Bool {
        didSet { defaults.set(showsHeroRecommendations, forKey: Key.showsHeroRecommendations) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⛔ 不用 bool(forKey:) 判「有没有存过」:它读一个存成字符串的值也会返回 false。
        // 一律按「没存过 = 默认开」处理 —— 用户只会通过这个开关显式关掉它。
        self.showsHeroRecommendations =
            defaults.object(forKey: Key.showsHeroRecommendations) as? Bool ?? Self.defaultShowsHeroRecommendations
    }

    /// 是否有任何一项偏离默认
    var isDefault: Bool {
        showsHeroRecommendations == Self.defaultShowsHeroRecommendations
    }

    static let defaultShowsHeroRecommendations = true

    /// UserDefaults key
    enum Key {
        static let showsHeroRecommendations = "home.showsHeroRecommendations"
    }

    @ObservationIgnored private let defaults: UserDefaults
}
