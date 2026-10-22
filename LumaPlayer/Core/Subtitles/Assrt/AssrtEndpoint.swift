import Foundation

/// assrt(伪射手)的端点拼装。事实来源是 <https://assrt.net/api/doc>,项目里没有单独文档,
/// 这里的注释就是事实记录。
///
/// - ⛔ token 不进查询串(会进 URL 日志),只用 `Authorization: Bearer`;
/// - `q` 至少 3 个字符、`cnt` 最多 15 条,是服务端硬限制,在这里夹住。
enum AssrtEndpoint {

    /// 搜索:`/v1/sub/search?q=&pos=&cnt=`
    case search(keyword: String, position: Int, count: Int)
    /// 详情:`/v1/sub/detail?id=`(文件列表与下载地址)
    case detail(id: Int)

    /// 文档另有备用域,不接:自动切域会让失败原因不可解释。
    static let defaultBaseURL = URL(string: "https://api.assrt.net")!

    static let maximumCount = 15

    /// 更短的会被 `status = 101` 拒绝
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
