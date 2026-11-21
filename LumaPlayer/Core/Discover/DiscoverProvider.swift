import Foundation

/// 榜单来源的种类。封闭集合:每种对应一个 `DiscoverProvider` 实现。
///
/// 与 `ResourceSourceAdapterKind` 同一立场:只把**协议稳定到值得写一个 adapter** 的来源做成实现,
/// 不做成用户可配置的抓取脚本 —— 站点改版该改代码,不该藏进 JSON。
enum DiscoverSourceKind: String, Sendable, CaseIterable {
    /// 豆瓣。⚠️ 未公开接口,随时可能失效(见 `docs/DISCOVERY.md` §3.4)
    case douban
    /// TMDB。要 v4 token,但协议是官方的
    case tmdb

    var displayName: String {
        switch self {
        case .douban: return "豆瓣"
        case .tmdb: return "TMDB"
        }
    }
}

/// 一组榜单的**配置**,不是 `enum` case:豆瓣有十几个 collection,写成 case 就得为每个发一次版。
/// 加一组榜单 = 加一条 `DiscoverBoard`。
struct DiscoverBoard: Sendable, Hashable, Identifiable {
    /// 全局唯一,同时当视图里的状态 key(来源前缀 + 引用,如豆瓣的热门剧集)。
    let id: String
    /// 货架标题
    let title: String
    let source: DiscoverSourceKind
    /// 源内部引用:豆瓣是 collection id(`tv_hot`),TMDB 是档位名(`trending`)
    let reference: String

    init(source: DiscoverSourceKind, reference: String, title: String) {
        self.id = "\(source.rawValue).\(reference)"
        self.title = title
        self.source = source
        self.reference = reference
    }
}

/// 某个来源这一轮**用不了**的原因。⛔ 不用「空榜单」冒充:用户必须知道是没配 token 还是接口挂了。
struct DiscoverUnavailable: Sendable, Equatable {
    let source: DiscoverSourceKind
    let message: String
    /// UI 据此给「去填 token」而不是「重试」
    let needsToken: Bool
}

/// 榜单数据源。一个 provider 管**一个来源的全部榜单**,只管取数与归一,不碰 UI 状态。
protocol DiscoverProvider: Sendable {
    var kind: DiscoverSourceKind { get }

    /// 这个来源现在能不能用。`nil` = 能用。⛔ 不抛错:不可用是常态(没配 token),不是异常。
    func availability() async -> DiscoverUnavailable?

    /// 这个来源提供哪些榜单,顺序即展示顺序。
    var boards: [DiscoverBoard] { get }

    /// 拉一页(`page` 0 起)。抛出的错误由 `DiscoveryViewModel` 折成该组自己的失败状态,⛔ 自己吞。
    func load(_ board: DiscoverBoard, page: Int) async throws -> DiscoverPage
}

/// 一页榜单条目 + 还有没有下一页。
///
/// 为什么要有这一层:两个来源的分页口径完全不同 —— 豆瓣是 `start/count` + `total`,
/// TMDB 是 `page` + `total_pages`。把它们折成「有没有下一页」这一件事,上层就不用知道细节。
struct DiscoverPage: Sendable, Equatable {
    let items: [DiscoverTitle]
    /// 还有下一页。⚠️ 不要用「本页是否装满」推断:豆瓣的末页就是不满的,而某些 collection 的总数
    /// 与 `total` 对不上。以来源自己给的边界为准。
    let hasMore: Bool

    init(items: [DiscoverTitle], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    static let empty = DiscoverPage(items: [], hasMore: false)
}


/// 榜单相关的失败。`userMessage` 给一句可解释的中文,⛔ 不把网络错误原样丢给用户。
enum DiscoverError: Error, Equatable {
    /// 不认识的榜单 id(provider 与 board 配错了)
    case unsupportedBoard(String)
    /// 非 2xx。`message` 只放服务端给的原因,不含响应体全文
    case http(statusCode: Int, message: String?)
    /// 连不上 / 响应不是 HTTP。⛔ 文本须已过 `SecretRedactor`(可能含带参数的 URL)
    case transport(String)
    /// 只带解码器描述,不带响应体
    case decoding(String)

    var userMessage: String {
        switch self {
        case .unsupportedBoard(let id):
            return "这个榜单还没有实现(\(id))。"
        case .http(let statusCode, let message):
            let detail = message.map { ":\($0)" } ?? ""
            // 403 / 418 是豆瓣风控挡下来的典型码,单独说清楚,免得用户以为是自己网络的问题
            if statusCode == 403 || statusCode == 418 {
                return "来源拒绝了这次请求(HTTP \(statusCode))\(detail),通常是反爬风控,过一会儿再试。"
            }
            return "来源返回了错误(HTTP \(statusCode))\(detail)。"
        case .transport(let detail):
            return "连接失败:\(detail)"
        case .decoding(let detail):
            return "解析来源的响应失败:\(detail)"
        }
    }
}
