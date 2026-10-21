import Foundation

/// assrt(伪射手)的端点拼装。
///
/// 事实来源是官方文档 <https://assrt.net/api/doc>(2026-10-21 核对),项目里没有
/// 单独的 API 文档 —— 这里的注释就是它的事实记录。
///
/// ## 两条约束
///
/// - **token 不进查询串**:文档给了 `?token=` 与 `Authorization: Bearer` 两种写法,
///   只用后者 —— 查询串会进 URL 日志与诊断文件(`CLAUDE.md`「安全与隐私」)。
/// - `q` **至少 3 个字符**、`cnt` **最多 15 条**:都是服务端硬限制,超了直接报错,
///   所以在这里夹一次,别让调用方去猜。
enum AssrtEndpoint {

    /// 搜索:`/v1/sub/search?q=&pos=&cnt=`
    case search(keyword: String, position: Int, count: Int)
    /// 详情:`/v1/sub/detail?id=`(拿文件列表与下载地址)
    case detail(id: Int)

    /// 主域。文档另给了一个备用域(网络原因时用),暂不接 ——
    /// 自动切域会让失败原因变得不可解释。
    static let defaultBaseURL = URL(string: "https://api.assrt.net")!

    /// 搜索一次最多返回多少条(服务端上限)。
    static let maximumCount = 15

    /// 关键词最短长度(服务端上限,`status = 101` 会拒绝更短的)。
    static let minimumKeywordLength = 3

    var path: String {
        switch self {
        case .search: return "/v1/sub/search"
        case .detail: return "/v1/sub/detail"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .search(let keyword, let position, let count):
            return [
                URLQueryItem(name: "q", value: keyword),
                URLQueryItem(name: "pos", value: String(max(0, position))),
                URLQueryItem(name: "cnt", value: String(min(max(1, count), Self.maximumCount))),
            ]
        case .detail(let id):
            return [URLQueryItem(name: "id", value: String(id))]
        }
    }

    func url(baseURL: URL = AssrtEndpoint.defaultBaseURL) -> URL? {
        var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url
    }
}
