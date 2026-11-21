import Foundation

/// 网盘类型。聚合搜索的结果按它分组,转存时据此挑「用哪个已登录来源去接」。
///
/// 取值对齐 PanSou 的 `cloud_types`(会话分析里那份清单),但⛔ 只保留本项目真能打开 / 转存的几类:
/// 磁力、ed2k、迅雷这类没有对应来源的也留着 —— 搜索结果照实显示,只是标成「本机没有可接的来源」,
/// 不能因为转存不了就把结果吞掉。
enum PanCloudType: String, Codable, Sendable, CaseIterable, Hashable {
    case baidu
    case quark
    case aliyun
    case pan115 = "115"
    case uc
    case tianyi
    case mobile
    case `123`
    case xunlei
    case pikpak
    case guangya
    case magnet
    case ed2k
    case unknown

    /// 展示名。⛔ 认不出来就显示「其它网盘」,不猜具体哪家。
    var displayName: String {
        switch self {
        case .baidu: return "百度网盘"
        case .quark: return "夸克网盘"
        case .aliyun: return "阿里云盘"
        case .pan115: return "115 网盘"
        case .uc: return "UC 网盘"
        case .tianyi: return "天翼云盘"
        case .mobile: return "移动云盘"
        case .`123`: return "123 云盘"
        case .xunlei: return "迅雷云盘"
        case .pikpak: return "PikPak"
        case .guangya: return "光雅"
        case .magnet: return "磁力链接"
        case .ed2k: return "电驴链接"
        case .unknown: return "其它网盘"
        }
    }

    /// 能不能「转存进网盘」。磁力 / ed2k 没有对应来源,只能交给外部客户端。
    var isTransferable: Bool {
        switch self {
        case .magnet, .ed2k, .unknown: return false
        default: return true
        }
    }
}

/// 一条资源里的一个链接。一条搜索结果可以带多个链接(同一部剧分几个网盘分享)。
struct PanResourceLink: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// 原始分享地址(`https://pan.baidu.com/s/xxx`、`magnet:?xt=…` 等)
    let url: String
    let cloudType: PanCloudType
    /// 提取码 / 访问码。nil = 这个链接不要码
    let password: String?

    /// `sheet(item:)` 用。分享地址本身就是唯一标识(同一地址不会出现两次)
    var id: String { url }

    var host: String? {
        URL(string: url)?.host()
    }
}

/// 归一化后的一条资源。字段与 PanSou 的 `SearchResult` 对齐,但只留本项目要用的:
/// 标题、来源、时间、链接。`content`(整段正文)只用于展示摘要,不进模型。
struct PanResource: Sendable, Equatable, Identifiable {
    /// 来源内唯一 id。由适配器给(插件名 + 该源的条目 id),用于去重与「这条来自哪」。
    let id: String
    /// 资源标题
    let title: String
    /// 正文摘要(可能是空的;搜索源常把「合集 / 更新到第 N 集」写在这里)
    let summary: String?
    /// 发布时间。nil = 源没给
    let publishedAt: Date?
    let links: [PanResourceLink]
    /// 产出这条资源的搜索源 id(见 `ResourceSource.id`),用于「这条来自哪」与按源屏蔽
    let sourceID: String
    /// 源自己给的排序权重(有的源带热度 / 等级)。nil = 没有
    let rank: Double?

    /// 按网盘类型分组时用:取第一个可转存链接的类型,没有可转存的就取第一个链接。
    var primaryCloudType: PanCloudType {
        links.first(where: { $0.cloudType.isTransferable })?.cloudType
            ?? links.first?.cloudType
            ?? .unknown
    }

    /// 去重键。同一分享链接出现在多个源里时只留信息更全的一条。
    ///
    /// ⚠️ 用**归一化后的分享地址**而不是标题:同一部剧在百度 / 夸克里是两条不同资源,
    /// 而同一个分享被两个源收录时地址完全一致。
    var deduplicationKey: String {
        let normalized = links.map { PanResource.normalizeShareURL($0.url) }.sorted().joined(separator: "|")
        return normalized.isEmpty ? "title:" + title : normalized
    }

    /// 把分享地址归一化到可比较的形式:去掉协议、查询串、尾斜杠,只留 host + path。
    ///
    /// ⚠️ 百度 / 夸克的分享地址里 `?pwd=xxxx` 与 `?share_type=xxx` 是同一份分享的不同写法,
    /// 带上查询串会让同一条资源被算成两条。
    static func normalizeShareURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host()?.lowercased() else {
            return trimmed.lowercased()
        }
        var path = url.path()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }
}

/// 一次聚合搜索的结果。
struct PanResourceSearchResult: Sendable, Equatable {
    let keyword: String
    let resources: [PanResource]
    /// 这次真正跑过的源
    let searchedSourceIDs: [String]
    /// 跑失败的源(⛔ 不隐藏:一个源挂了不代表没有结果,但用户要知道「这次少搜了谁」)
    let failures: [PanResourceSourceFailure]

    var isEmpty: Bool { resources.isEmpty }
}

/// 一个搜索源失败的原因。`message` 已经过脱敏,可直接展示。
struct PanResourceSourceFailure: Sendable, Equatable, Identifiable {
    /// 与 `ResourceSource.id` 同值
    let sourceID: String
    let displayName: String
    let message: String

    var id: String { sourceID }
}
