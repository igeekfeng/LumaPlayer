import Foundation
import os

/// assrt(伪射手)的 HTTP 客户端:纯传输 + 解码,⛔ 不含 token 存储、不碰凭据。
///
/// 分工与 `TMDBClient` / `BaiduPanAPIClient` 一致:token 由调用方逐次传入,
/// 客户端无状态(`Sendable`),「token 从哪来」在上层(`SubtitleService`)。
///
/// ## 两个安全细节
///
/// 1. token 走 `Authorization: Bearer`,⛔ 不进查询串(会被 URL 日志带走)。
/// 2. **下载不带 token**:下载地址在 `file0.assrt.net` 这类独立主机上,
///    地址自带签名 —— 把 token 发给另一台主机是没必要的泄漏。
struct AssrtClient: Sendable {

    init(session: URLSession? = nil, baseURL: URL = AssrtEndpoint.defaultBaseURL) {
        if let session {
            self.session = session
        } else {
            // 与 TMDB 同一处置:不缓存、不存 cookie —— 搜索结果要「刚改就能看到」
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

    /// 按关键词搜字幕。一次最多 15 条(服务端上限),不做分页 ——
    /// 用户真正要的是「挑一条能用的」,翻页只会多花配额。
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

    /// 取一条字幕的文件列表与下载地址。
    ///
    /// ⚠️ 返回的地址是**一次性**的(文档原话:每次生成都不同、有有效期),
    /// ⛔ 不要缓存 URL;要缓存就缓存下载下来的**文件**。
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

    /// 下载一个字幕文件(不带认证头,见类型注释)。
    ///
    /// 大小上限复用 `SubtitleFileStore.maximumBytes`:超了直接拒,⛔ 不把整个文件读进内存
    /// 再交给 mpv —— 误点一个视频文件就会吃掉几百 MB。
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
        guard (200...299).contains(http.statusCode) else {
            throw AssrtError.server(message: "下载失败(HTTP \(http.statusCode))")
        }
        guard data.count <= SubtitleFileStore.maximumBytes else {
            throw AssrtError.server(message: "文件超过 \(SubtitleFileStore.maximumBytes / (1024 * 1024)) MB")
        }
        return data
    }

    // MARK: - 传输与解码

    /// 构造一次 API 请求。
    ///
    /// 单独成方法是为了**能被断言**:token 必须在 `Authorization` 头里、
    /// ⛔ 不能出现在 URL 上(URL 会进日志与诊断文件)。
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
            // 不吞错:响应格式变了要能看出来,而不是显示「没有结果」
            Self.logger.error("assrt 响应解析失败:\(String(describing: error), privacy: .public)")
            throw AssrtError.transport("响应格式不对")
        }
    }

    /// 只解 `status` / `message` —— 非 2xx 时先判断业务码用。
    private struct AssrtStatusOnly: Decodable {
        let status: Int
        let message: String?
    }
}
