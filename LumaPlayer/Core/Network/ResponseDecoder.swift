import Foundation

/// JSON 解码,错误统一包成 `.decoding`(API_CONTRACT.md 第 7 节)。
/// 每次新建 `JSONDecoder`,不跨隔离共享可变对象。
struct ResponseDecoder: Sendable {
    func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data,
        endpointName: String
    ) throws -> T {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: data)
        } catch {
            // 只带端点名,不带原始数据:响应里可能有 token
            throw EmbyAPIError.decoding(underlying: String(describing: error), endpointName: endpointName)
        }
    }
}
