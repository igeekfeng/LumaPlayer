import Foundation

/// 单台服务器的 HTTP 客户端。⛔ 每台一个实例,token 是实例状态、不共享。
///
/// 只如实抛 `.unauthorized`,401 处置在 `ServerConnection`(API_CONTRACT.md 2.5)。
actor EmbyAPIClient {
    private var builder: EmbyRequestBuilder
    private let session: URLSession
    private let decoder: ResponseDecoder
    private var accessToken: String?
    private var userID: String?

    init(
        builder: EmbyRequestBuilder,
        session: URLSession = .shared,
        accessToken: String? = nil,
        userID: String? = nil
    ) {
        self.builder = builder
        self.session = session
        self.decoder = ResponseDecoder()
        self.accessToken = accessToken
        self.userID = userID
    }

    // MARK: - 连接参数(探测后回填)

    /// 探测确定后写入,之后不再猜(API_CONTRACT.md 1.4)
    func updatePathPrefix(_ prefix: String) {
        builder.apiPathPrefix = prefix
    }

    /// http 回退会改 scheme(API_CONTRACT.md 1.4)
    func updateBaseURL(_ url: URL) {
        builder.baseURL = url
    }

    func setCredentials(accessToken: String?, userID: String?) {
        self.accessToken = accessToken
        self.userID = userID
    }

    var hasToken: Bool {
        accessToken != nil
    }

    /// 只给 `ServerConnection` 判断 401 的那次请求用的是不是当前 token。⛔ 不得进日志。
    var currentAccessToken: String? {
        accessToken
    }

    // MARK: - 请求

    func send<T: Decodable & Sendable>(_ endpoint: EmbyEndpoint) async throws -> T {
        let (value, _) = try await sendCaching(T.self, endpoint)
        return value
    }

    /// 额外带回原始响应字节供缓存落盘(DTO 只有 `Decodable`,不能重编码)。
    /// 显式传类型:返回元组时泛型参数无从推断。
    func sendCaching<T: Decodable & Sendable>(
        _ type: T.Type,
        _ endpoint: EmbyEndpoint
    ) async throws -> (T, Data) {
        let (data, http, request) = try await perform(endpoint)
        do {
            let value = try decoder.decode(type, from: data, endpointName: endpoint.name)
            return (value, data)
        } catch {
            // 2xx 解不成模型是服务端版本差异最常见的形态;响应体只在诊断出口脱敏后留一份
            if let apiError = error as? EmbyAPIError, case .decoding(let detail, _) = apiError {
                diagnose(.decoding(status: http.statusCode, detail: detail, body: data),
                         endpoint: endpoint, request: request)
            }
            throw error
        }
    }

    /// 缓存命中路径的解码。解不出 = 条目损坏,调用方删条目重走网络,不做诊断留档。
    func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data,
        endpointName: String
    ) throws -> T {
        try decoder.decode(type, from: data, endpointName: endpointName)
    }

    func sendVoid(_ endpoint: EmbyEndpoint) async throws {
        _ = try await perform(endpoint)
    }

    /// 二进制端点(图片,API_CONTRACT.md 3.3),认证头与状态码映射与 JSON 相同。
    func sendData(_ endpoint: EmbyEndpoint) async throws -> Data {
        let (data, _, _) = try await perform(endpoint)
        return data
    }

    private func perform(
        _ endpoint: EmbyEndpoint
    ) async throws -> (Data, HTTPURLResponse, URLRequest) {
        let request = try builder.makeRequest(
            for: endpoint,
            accessToken: accessToken,
            userID: userID
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            // 取消是正常流程,单独映射(API_CONTRACT.md 第 7 节),不进诊断日志
            if urlError.code == .cancelled {
                throw EmbyAPIError.cancelled
            }
            diagnose(.transport(urlError.code), endpoint: endpoint, request: request)
            throw EmbyAPIError.transport(urlError.code)
        } catch {
            diagnose(.transport(.unknown), endpoint: endpoint, request: request)
            throw EmbyAPIError.transport(.unknown)
        }
        guard let http = response as? HTTPURLResponse else {
            diagnose(.transport(.badServerResponse), endpoint: endpoint, request: request)
            throw EmbyAPIError.transport(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            // 先留诊断再抛:UI 只有状态码,服务端原话只能在这里留下(PITFALLS.md Q31)
            diagnose(.http(status: http.statusCode, body: data), endpoint: endpoint, request: request)
            throw EmbyAPIError.mapping(statusCode: http.statusCode)
        }
        return (data, http, request)
    }

    /// 请求体原样交出,脱敏由 `NetworkDiagnostics` 负责(含登录体里的 `Pw`)。
    private func diagnose(_ failure: NetworkDiagnostics.Failure, endpoint: EmbyEndpoint, request: URLRequest) {
        NetworkDiagnostics.record(
            failure,
            endpointName: endpoint.name,
            method: endpoint.method,
            url: request.url ?? builder.baseURL,
            requestBody: request.httpBody
        )
    }
}
