import Foundation

/// TMDB 的 HTTP 客户端:纯传输 + 解码,无状态,token 由调用方逐次传入,⛔ 不碰凭据存储。
///
/// token 走 `Authorization: Bearer` 头(`docs/TMDB_API.md` §1),⛔ 不进查询串(会被缓存 / 日志落盘)。
/// 错误映射见 `failure(statusCode:data:)`(§5);`status_message` 不含凭据,可展示。
struct TMDBClient: Sendable {

    /// 默认用独立会话,关缓存与 cookie:刮削结果要即改即见,且不落盘。
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
    }

    private let session: URLSession

    /// 让 `overview` 回中文(§1)。
    static let defaultLanguage = "zh-CN"

    // MARK: - 搜索

    func searchMovie(
        title: String,
        year: Int? = nil,
        token: String,
        language: String = TMDBClient.defaultLanguage
    ) async throws -> [TMDBMatch] {
        try await search(
            endpoint: .searchMovie(query: title, year: year, language: language),
            kind: .movie,
            token: token
        )
    }

    func searchTV(
        title: String,
        year: Int? = nil,
        token: String,
        language: String = TMDBClient.defaultLanguage
    ) async throws -> [TMDBMatch] {
        try await search(
            endpoint: .searchTV(query: title, year: year, language: language),
            kind: .tv,
            token: token
        )
    }

    /// 是不是剧集由调用方判断(刮削链路上看 `BaiduPanMetadataSynthesizer.parse` 有没有解析到集号),⛔ 客户端不猜。
    func search(
        title: String,
        year: Int? = nil,
        isSeries: Bool,
        token: String,
        language: String = TMDBClient.defaultLanguage
    ) async throws -> [TMDBMatch] {
        isSeries
            ? try await searchTV(title: title, year: year, token: token, language: language)
            : try await searchMovie(title: title, year: year, token: token, language: language)
    }

    private func search(
        endpoint: TMDBEndpoint,
        kind: TMDBMatch.Kind,
        token: String
    ) async throws -> [TMDBMatch] {
        let data = try await send(endpoint, token: token)
        let response: TMDBSearchResponse = try decode(data, endpoint: endpoint)
        return response.results.map { TMDBMatch(result: $0, kind: kind) }
    }

    // MARK: - 季详情

    /// 返回整季 `episodes[]`(§7),调用方按 `episodeNumber` 匹配文件。`seriesID` 是 TMDB id。
    /// 季不存在 → `TMDBError.notFound`。
    func seasonDetails(
        seriesID: Int,
        seasonNumber: Int,
        token: String,
        language: String = TMDBClient.defaultLanguage
    ) async throws -> [TMDBEpisode] {
        let endpoint = TMDBEndpoint.tvSeason(
            seriesID: seriesID, seasonNumber: seasonNumber, language: language)
        let data = try await send(endpoint, token: token)
        let response: TMDBSeasonResponse = try decode(data, endpoint: endpoint)
        return response.episodes
    }

    // MARK: - 按 id 直取

    /// 按 `{tmdbid-…}` 直取,跳过搜索。影 / 剧是两个 id 空间,`isSeries` 由调用方按上下文给。
    /// 两种响应字段名不同,都解进 `TMDBResult`,由 `TMDBMatch(result:kind:)` 归一。不存在 → `.notFound`。
    func details(
        id: Int,
        isSeries: Bool,
        token: String,
        language: String = TMDBClient.defaultLanguage
    ) async throws -> TMDBMatch {
        let endpoint: TMDBEndpoint = isSeries
            ? .tvDetails(id: id, language: language)
            : .movieDetails(id: id, language: language)
        let data = try await send(endpoint, token: token)
        let result: TMDBResult = try decode(data, endpoint: endpoint)
        return TMDBMatch(result: result, kind: isSeries ? .tv : .movie)
    }

    // MARK: - 演职员

    /// 整部作品(非单季 / 单集)的演职员(§10)。`isSeries` 同 `details`。
    /// 滤掉没名字的人(⛔ 不伪造名字);`cast` 按 TMDB 给的 `order` 排,⛔ 不按别的字段重排。
    func credits(
        id: Int,
        isSeries: Bool,
        token: String,
        language: String = TMDBClient.defaultLanguage
    ) async throws -> TMDBCredits {
        let endpoint: TMDBEndpoint = isSeries
            ? .tvCredits(id: id, language: language)
            : .movieCredits(id: id, language: language)
        let data = try await send(endpoint, token: token)
        let response: TMDBCreditsResponse = try decode(data, endpoint: endpoint)
        return TMDBCredits(
            cast: (response.cast ?? []).filter { !$0.name.isEmpty }
                .sorted { $0.order < $1.order },
            crew: (response.crew ?? []).filter { !$0.name.isEmpty }
        )
    }

    // MARK: - 传输与解码

    /// 只做传输层校验。
    func send(_ endpoint: TMDBEndpoint, token: String) async throws -> Data {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空 token 不去请求:TMDB 会回 401,用户该看到的是「去填 token」而不是「token 无效」
        guard !trimmed.isEmpty else { throw TMDBError.tokenMissing }
        guard let url = endpoint.url else {
            throw TMDBError.transport("接口地址构造失败(\(endpoint.name))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TMDBError.transport("响应不是 HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.failure(statusCode: http.statusCode, data: data)
            }
            return data
        } catch let error as TMDBError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // ⛔ 不用 `String(describing: error)`:`URLError` 的 userInfo 带完整 URL
            let nsError = error as NSError
            throw TMDBError.transport(
                SecretRedactor.redacted("\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)"))
        }
    }

    static func failure(statusCode: Int, data: Data) -> TMDBError {
        let envelope = try? JSONDecoder().decode(TMDBFailureEnvelope.self, from: data)
        switch statusCode {
        case 401:
            return .unauthorized(code: envelope?.statusCode, message: envelope?.statusMessage)
        case 404:
            return .notFound(message: envelope?.statusMessage)
        case 429:
            return .rateLimited(message: envelope?.statusMessage)
        default:
            return .server(statusCode: statusCode, message: envelope?.statusMessage)
        }
    }

    /// 失败只带端点名与解码器描述,⛔ 不带响应体。
    func decode<T: Decodable & Sendable>(_ data: Data, endpoint: TMDBEndpoint) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TMDBError.decoding(detail: "\(endpoint.name):\(Self.describe(error))")
        }
    }

    /// 点名到字段,排障时能直接看出哪个字段对不上。
    private static func describe(_ error: any Error) -> String {
        switch error {
        case let decoding as DecodingError:
            switch decoding {
            case .keyNotFound(let key, _):
                return "缺少字段 \(key.stringValue)"
            case .typeMismatch(let type, let context):
                return "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 类型不是 \(type)"
            case .valueNotFound(let type, let context):
                return "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 为 null(期望 \(type))"
            case .dataCorrupted(let context):
                return "响应不是合法 JSON(\(context.debugDescription))"
            @unknown default:
                return "无法解析"
            }
        default:
            return "\(error)"
        }
    }
}

/// `{"status_code":7,"status_message":"...","success":false}`(§5)。全可选:形状不对仍能按状态码下结论。
private struct TMDBFailureEnvelope: Decodable {
    let statusCode: Int?
    let statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_message"
    }
}