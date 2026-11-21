import Foundation

/// 一个搜索源的**配置**(可维护的那部分)。放 JSON 里,设置页可增删改,⛔ 不写死在代码里。
///
/// 设计取舍(会话分析的结论):PanSou 的能力来自「几十个源 + 统一接口」,
/// 源列表本身是会腐烂的(站点关停、接口加反爬)。所以这里把**源清单**做成数据,
/// 把**抓取方式**做成一个小的封闭适配器集合(`ResourceSourceAdapterKind`)。
/// 加一个同类源 = 加一条 JSON;加一种新抓取方式 = 加一个 adapter case。
struct ResourceSource: Codable, Sendable, Equatable, Identifiable {
    /// 稳定 id(去重、屏蔽、失败归因都用它)。⛔ 不要跟着 displayName 改
    let id: String
    var displayName: String
    var kind: ResourceSourceAdapterKind
    /// 站点根地址(不带路径)。`https://so.example.com`
    ///
    /// ⚠️ `telegramChannel` 这一档存的是**频道名**(见 `ResourceSourceAdapterKind`)。
    var baseURL: String
    /// 可选:某些源要 API key / token。⛔ 它属于凭据,不落这个 JSON,存 `CredentialStore`
    var requiresCredential: Bool
    var isEnabled: Bool
    /// 备注,展示在设置页(比如「2026-09 起接口加反爬」)
    var note: String?

    init(
        id: String,
        displayName: String,
        kind: ResourceSourceAdapterKind,
        baseURL: String,
        requiresCredential: Bool = false,
        isEnabled: Bool = true,
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.requiresCredential = requiresCredential
        self.isEnabled = isEnabled
        self.note = note
    }

    /// 配置是否可用:地址能解析出 host、kind 需要的字段齐全。
    /// ⛔ 返回原因而不是 Bool:设置页要把「为什么这条不能用」说出来。
    var validationFailure: String? {
        switch kind {
        case .panSou:
            guard let url = URL(string: baseURL), url.host() != nil else {
                return "地址无效:\(baseURL)"
            }
            return nil
        case .telegramChannel:
            // 这一档的 `baseURL` 存的是频道名(不是站点根地址),所以不能按 URL 校验
            guard TelegramChannelAdapter.channelName(from: baseURL) != nil else {
                return "频道名无效:\(baseURL)"
            }
            return nil
        }
    }
}

/// 抓取方式的种类。封闭集合:每种对应一个 `ResourceSourceAdapter` 实现。
///
/// 为什么是封闭的:会话里验证过,PanSou 那 100 多个站点里大量依赖站点私有加密 / 登录态,
/// 把它们全做成配置项等于把「一个站改版就要改代码」藏进 JSON。这里只把**协议稳定**的几类配置化:
/// 自建 / 他人部署的 PanSou 实例,以及 Telegram 公开频道。
enum ResourceSourceAdapterKind: String, Codable, Sendable, CaseIterable {
    /// PanSou 实例:`GET|POST /api/search?kw=`
    ///
    /// ⚠️ 保留但不预置:PanSou 会把关键词扇到上百个源,结果杂;
    /// 默认走下面的频道源,这一档留给想接自己实例的人。
    case panSou

    /// Telegram 公开频道:`GET https://t.me/s/{频道}?q={关键词}`
    ///
    /// 这一档的 `baseURL` 存**频道名**(`tgsearchers7` 或 `https://t.me/tgsearchers7`),
    /// 不是站点根地址 —— 一个源就是一个频道,这样才能「自己维护小而精的频道清单」。
    case telegramChannel

    var displayName: String {
        switch self {
        case .panSou: return "PanSou 实例"
        case .telegramChannel: return "Telegram 频道"
        }
    }

    /// 设置页给用户的填写提示
    var baseURLHint: String {
        switch self {
        case .panSou: return "https://your-pansou-host"
        case .telegramChannel: return "tgsearchers7 或 https://t.me/tgsearchers7"
        }
    }

    /// 这一档的「地址」是不是站点根地址(决定校验方式与展示文案)
    var addressIsChannelName: Bool {
        switch self {
        case .panSou: return false
        case .telegramChannel: return true
        }
    }
}
