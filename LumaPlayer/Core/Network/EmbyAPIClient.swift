import Foundation

/// 单台服务器的 HTTP 客户端(actor,ARCHITECTURE.md 3.1.2)。
///
/// ⛔ **每台服务器一个实例,token 不共享**(6.3 架构约束)—— token 是实例状态,
/// 不是静态单例,这样一台服务器 401 时不可能污染另一台。
///
/// 401 的处置策略(清 token / 标记重新登录)不在本类:本类只如实抛
/// `EmbyAPIError.unauthorized`,由 `ServerConnection` 按 API_CONTRACT.md 2.5 处理。
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

    /// `/emby` 前缀由探测确定后写入,之后不再猜(API_CONTRACT.md 1.4)
    func updatePathPrefix(_ prefix: String) {
        builder.apiPathPrefix = prefix
    }

    /// http 回退会让站点根的 scheme 变化(API_CONTRACT.md 1.4)
    func updateBaseURL(_ url: URL) {
        builder.baseURL = url
    }

    /// 登录后写入 / 登出后清空。
    func setCredentials(accessToken: String?, userID: String?) {
        self.accessToken = accessToken
        self.userID = userID
    }

    var hasToken: Bool {
        accessToken != nil
    }

    /// 当前持有的 token。只给 `ServerConnection` 判断「401 的那次请求用的是不是
    /// 现在这个 token」—— 并发请求里别人已经换上新 token 时,不能再拿旧 401 把新的删掉。
    /// ⛔ 不得进日志。
    var currentAccessToken: String? {
        accessToken
    }

    // MARK: - 请求

    func send<T: Decodable & Sendable>(_ endpoint: EmbyEndpoint) async throws -> T {
        let (value, _) = try await sendCaching(T.self, endpoint)
        return value
    }

    /// `send` 的变体:额外带回原始响应字节,供接口缓存落盘
    /// (`EmbyResponseCache` 存原始字节 —— DTO 只有 `Decodable`,不能重编码解码值)。
    /// 诊断分支与 `send` 完全一致。显式传类型是因为返回值是元组,
    /// 泛型参数没有上下文可推断。
    func sendCaching<T: Decodable & Sendable>(
        _ type: T.Type,
        _ endpoint: EmbyEndpoint
    ) async throws -> (T, Data) {
        let (data, http, request) = try await perform(endpoint)
        do {
            let value = try decoder.decode(type, from: data, endpointName: endpoint.name)
            return (value, data)
        } catch {
            // 2xx 但解不成模型,是服务端版本差异最常见的形态(字段改类型、变 null、换结构)。
            // `ResponseDecoder` 按规则不带原始数据,响应体只在诊断出口里脱敏后留一份
            if let apiError = error as? EmbyAPIError, case .decoding(let detail, _) = apiError {
                diagnose(.decoding(status: http.statusCode, detail: detail, body: data),
                         endpoint: endpoint, request: request)
            }
            throw error
        }
    }

    /// 缓存命中路径的解码:数据是曾经成功解码过才落盘的原始字节,
    /// 这里解不出 = 缓存条目损坏,由调用方(`ServerConnection`)删条目按 miss
    /// 重走网络,所以不需要网络侧的诊断留档。
    func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data,
        endpointName: String
    ) throws -> T {
        try decoder.decode(type, from: data, endpointName: endpointName)
    }

    /// 只关心成功与否的端点(如 `/Sessions/Logout`)
    func sendVoid(_ endpoint: EmbyEndpoint) async throws {
        _ = try await perform(endpoint)
    }

    /// 取原始响应体(图片等二进制端点,API_CONTRACT.md 3.3)。
    ///
    /// 图片与 JSON 走同一套认证头与状态码映射 —— 因此图片请求的唯一出口是
    /// `Components/PosterImage.swift`(见该文件注释)。
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
            // 取消是正常流程(翻页/切服务器),必须单独映射(API_CONTRACT.md 第 7 节),
            // 也不进诊断日志 —— 否则每次翻页都刷一行
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
            // 先留诊断痕迹再抛。UI 只给得出「服务器返回异常状态码(400)」这种
            // 由状态码反推的文案,服务端的原因原话得由这里留下,否则真实服务器
            // 上的 400 永远无从定位(docs/PITFALLS.md Q31)。
            diagnose(.http(status: http.statusCode, body: data), endpoint: endpoint, request: request)
            throw EmbyAPIError.mapping(statusCode: http.statusCode)
        }
        return (data, http, request)
    }

    /// 诊断出口的唯一入口。请求体原样交出去,脱敏由 `NetworkDiagnostics` 负责
    /// (登录请求体里有 `Pw`,那边按 JSON 结构整值替换)。
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
