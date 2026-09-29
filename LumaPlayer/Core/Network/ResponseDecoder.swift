import Foundation

/// JSON 解码与解码错误的统一包装(API_CONTRACT.md 第 7 节的 `.decoding`)。
///
/// 不持有 `JSONDecoder` 实例:每次解码新建,避免跨隔离共享可变对象
/// (ARCHITECTURE.md 3.1.2)。
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
            // 只带端点名,不带原始数据:响应里可能有 token,不得进日志
            // (ARCHITECTURE.md 8.1)
            throw EmbyAPIError.decoding(underlying: String(describing: error), endpointName: endpointName)
        }
    }
}
