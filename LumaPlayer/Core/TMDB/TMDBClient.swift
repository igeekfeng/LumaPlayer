import Foundation

/// TMDB 的 HTTP 客户端(纯传输 + 解码,⛔ 不含 token 存储、不碰凭据)。
///
/// 与 `BaiduPanAPIClient` 的分工一致:查询串拼装与错误映射在这里,
/// 「token 从哪来」「token 没有怎么办」在上层(`CredentialStore` + 调用方)。
/// token 由**调用方逐次传入** —— 客户端本身无状态(`Sendable` struct),
/// 与 `BaiduPanAPIClient` 一样按调用点拿 `access_token`。
///
/// ## 认证(`docs/TMDB_API.md` §1)
///
/// v4 Read Access Token 走 `Authorization: Bearer <token>` 请求头。
/// ⛔ token **不进查询串**:那会被 URLSession 的缓存 / 日志写进磁盘。
///
/// ## 错误映射(`docs/TMDB_API.md` §5)
///
/// HTTP 401 → `.unauthorized`(token 无效);429 → `.rateLimited`;404 → `.notFound`;
/// 其余非 2xx → `.server`。响应体里的 `status_message` 取来一起展示(它不含凭据)。
struct TMDBClient: Sendable {

    /// ⚠️ 用独立的会话:关掉缓存与 cookie —— 刮削结果要「刚改过就能看到」,
    /// 且不把任何东西落盘(与 `BaiduPanAPIClient` 同一处置)。
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

    /// 默认搜索语言。`zh-CN`(ISO 639-1 + ISO 3166-1,§1)让 `overview` 回来是中文 ——
    /// 本 App 面向中文用户。解析不出更合适的语言就固定用它。
    static let defaultLanguage = "zh-CN"

    // MARK: - 搜索

    /// 搜电影。
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

    /// 搜剧集。
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

    /// 按「是不是剧集」自动选端点。
    ///
    /// 判据由调用方给 —— 刮削链路上是 `BaiduPanMetadataSynthesizer.parse` 解析出的
    /// 季集(解析到 `episode` 就算剧集)。⛔ 客户端自己不猜。
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

    /// 取一季的分集(剧照 / 集名 / 单集简介),`docs/TMDB_API.md` §7。
    ///
    /// `seriesID` 来自 `searchTV` 命中的 `tmdbID`(⛔ 不要拿文件名当 id)。
    /// 返回**整季** `episodes[]`;调用方按 `episodeNumber` 自己匹配 ——
    /// 客户端不猜哪一集对应哪个文件。
    ///
    /// 季不存在时服务端回 404 → `TMDBError.notFound`(§7)。
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

    // MARK: - 传输与解码

    /// 发一次请求,返回响应体。只做传输层校验(HTTP 状态、是否 HTTP 响应)。
    func send(_ endpoint: TMDBEndpoint, token: String) async throws -> Data {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⛔ 空 token 不假装去请求:TMDB 会回 401,而那条错误对用户毫无指引
        // (「去填 token」是这一档该说的话,不是「token 无效」)
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
            // ⛔ 绝不 `String(describing: error)`:`URLError` 的 userInfo 里带
            // `NSURLErrorFailingURLStringErrorKey`(CLAUDE.md「安全与隐私」)。
            // 取域 + 码 + 描述再过脱敏。
            let nsError = error as NSError
            throw TMDBError.transport(
                SecretRedactor.redacted("\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)"))
        }
    }

    /// 把非 2xx 折成 `TMDBError`(官方错误表 §5)。
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

    /// 解码。解码失败只带端点名与解码器描述,⛔ **不带响应体**。
    func decode<T: Decodable & Sendable>(_ data: Data, endpoint: TMDBEndpoint) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TMDBError.decoding(detail: "\(endpoint.name):\(Self.describe(error))")
        }
    }

    /// `DecodingError` 的可读描述。`keyNotFound` / `typeMismatch` 都点名到字段,
    /// 排障时能直接看出是哪个字段对不上(这正是「核实字段名」的反馈回路)。
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

/// 失败响应体(`docs/TMDB_API.md` §5):
/// `{"status_code":7,"status_message":"...","success":false}`。
/// 全部可选:形状不对时 `failure(statusCode:data:)` 仍能按状态码给出结论。
private struct TMDBFailureEnvelope: Decodable {
    let statusCode: Int?
    let statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_message"
    }
}