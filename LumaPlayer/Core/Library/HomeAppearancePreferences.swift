import Foundation

/// 首页偏好(UserDefaults,全部服务器共用)。
///
/// `showsHeroRecommendations` 关闭时整个 hero 不显示,也不发随机推荐请求(`HomeViewModel.load`);
/// ⛔ 不从「继续观看 / 各库最新」找替补顶上 —— 那条退路只用于推荐请求失败(`HomeViewModel.heroPick`)。
@MainActor
@Observable
final class HomeAppearancePreferences {

    // MARK: - 偏好项

    /// 首页顶部是否显示随机推荐的 hero 轮播
    var showsHeroRecommendations: Bool {
        didSet { defaults.set(showsHeroRecommendations, forKey: Key.showsHeroRecommendations) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⛔ 不用 bool(forKey:):类型不对也返回 false。没存过 = 默认开
        self.showsHeroRecommendations =
            defaults.object(forKey: Key.showsHeroRecommendations) as? Bool ?? Self.defaultShowsHeroRecommendations
    }

    var isDefault: Bool {
        showsHeroRecommendations == Self.defaultShowsHeroRecommendations
    }

    static let defaultShowsHeroRecommendations = true

    enum Key {
        static let showsHeroRecommendations = "home.showsHeroRecommendations"
    }

    @ObservationIgnored private let defaults: UserDefaults
}
