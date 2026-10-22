import Foundation
import os

/// assrt 的 HTTP 客户端:纯传输 + 解码,无状态,token 由调用方逐次传入。
///
/// - token 走 `Authorization: Bearer`,⛔ 不进查询串;
/// - ⛔ 下载不带 token:下载地址在 `file0.assrt.net` 等独立主机,自带签名。
struct AssrtClient: Sendable {

    init(session: URLSession? = nil, baseURL: URL = AssrtEndpoint.defaultBaseURL) {
        if let session {
            self.session = session
        } else {
            // 不缓存、不存 cookie(同 TMDB)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
    }

    private let session: URLSession
    private let baseURL: URL

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    // MARK: - 搜索

    /// 一次最多 15 条,不分页(翻页只会多花配额)。
    func search(keyword: String, token: String) async throws -> [AssrtSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= AssrtEndpoint.minimumKeywordLength else {
            throw AssrtError.keywordTooShort
        }
        let endpoint = AssrtEndpoint.search(
            keyword: trimmed, position: 0, count: AssrtEndpoint.maximumCount)
        let data = try await send(endpoint, token: token)
        let envelope: AssrtSearchEnvelope = try decode(data)
        if let error = AssrtError.from(status: envelope.status, message: envelope.message) {
            throw error
        }
        let results = (envelope.sub?.subs ?? []).map(\.result)
        Self.logger.info("assrt 搜索命中 \(results.count) 条")
        return results
    }

    // MARK: - 详情

    /// ⚠️ 返回的地址是一次性的,⛔ 不要缓存 URL,要缓存就缓存文件。
    func detail(id: Int, token: String) async throws -> AssrtSubtitleDetail {
        let data = try await send(.detail(id: id), token: token)
        let envelope: AssrtDetailEnvelope = try decode(data)
        if let error = AssrtError.from(status: envelope.status, message: envelope.message) {
            throw error
        }
        guard let dto = envelope.sub?.subs?.first else { throw AssrtError.notFound }
        return dto.detail
    }

    // MARK: - 下载

    /// 不带认证头。超过 `SubtitleFileStore.maximumBytes` 直接拒。
    func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AssrtError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AssrtError.transport("响应不是 HTTP")
        }
        if let rejection = Self.downloadRejection(finalURL: http.url) {
            throw rejection
        }
        guard (200...299).contains(http.statusCode) else {
            throw AssrtError.server(message: "下载失败(HTTP \(http.statusCode))")
        }
        guard data.count <= SubtitleFileStore.maximumBytes else {
            throw AssrtError.server(message: "文件超过 \(SubtitleFileStore.maximumBytes / (1024 * 1024)) MB")
        }
        return data
    }

    /// 下载失败时 file0 会 302 到主站错误页 `/download/failed/…`(492)或 `/download/error/…`(493)。
    /// URLSession 会跟随跳转,所以看最终地址识别。
    static func downloadRejection(finalURL: URL?) -> AssrtError? {
        guard let url = finalURL, let host = url.host()?.lowercased(),
              host == "assrt.net" || host.hasSuffix(".assrt.net") else { return nil }
        if url.path.hasPrefix("/download/failed/") { return .downloadRejected(expired: true) }
        if url.path.hasPrefix("/download/error/") { return .downloadRejected(expired: false) }
        return nil
    }

    // MARK: - 传输与解码

    /// 单独成方法供测试断言 token 只在头里、不在 URL 上。
    func request(for endpoint: AssrtEndpoint, token: String) throws -> URLRequest {
        guard !token.isEmpty else { throw AssrtError.missingToken }
        guard let url = endpoint.url(baseURL: baseURL) else {
            throw AssrtError.transport("地址拼装失败")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ endpoint: AssrtEndpoint, token: String) async throws -> Data {
        let request = try request(for: endpoint, token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AssrtError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AssrtError.transport("响应不是 HTTP")
        }
        guard (200...299).contains(http.statusCode) else {
            // 业务错误也可能是 4xx(`ClientFail`),先试着从 body 里读 status 码
            if let envelope = try? JSONDecoder().decode(AssrtStatusOnly.self, from: data),
               let error = AssrtError.from(status: envelope.status, message: envelope.message) {
                throw error
            }
            throw http.statusCode == 401 || http.statusCode == 403
                ? AssrtError.invalidToken
                : AssrtError.server(message: "HTTP \(http.statusCode)")
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // 响应格式变了要能看出来,而不是显示「没有结果」
            Self.logger.error("assrt 响应解析失败:\(String(describing: error), privacy: .public)")
            throw AssrtError.transport("响应格式不对")
        }
    }

    /// 非 2xx 时先判断业务码用。
    private struct AssrtStatusOnly: Decodable {
        let status: Int
        let message: String?
    }
}
