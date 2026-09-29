import Foundation

/// Emby 接口错误。**所有端点共用同一套映射**(API_CONTRACT.md 第 7 节)。
enum EmbyAPIError: Error, Equatable, Sendable {
    /// 401 —— token 失效,触发重新登录(仅该服务器,API_CONTRACT.md 2.5)
    case unauthorized
    /// 403 —— 权限不足,**不**清 token、不提示重新登录
    case forbidden
    case notFound
    case rateLimited
    case server(status: Int)
    case unexpectedStatus(Int)
    case decoding(underlying: String, endpointName: String)
    case transport(URLError.Code)
    /// 主动取消:UI 不得显示为错误(翻页、切服务器时的取消是正常流程)
    case cancelled

    /// 非 2xx 状态码 → case(API_CONTRACT.md 第 7 节的映射表)。
    static func mapping(statusCode: Int) -> EmbyAPIError {
        switch statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited
        case 500...599: return .server(status: statusCode)
        default: return .unexpectedStatus(statusCode)
        }
    }
}
