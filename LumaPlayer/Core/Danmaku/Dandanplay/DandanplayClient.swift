import CryptoKit
import Foundation

/// 弹弹play 应用凭据(`docs/DANDANPLAY_API.md` §1)。用户在设置页自填,存凭据文件,⛔ 不进仓库、不进 UserDefaults。
struct DandanplayCredentials: Codable, Sendable, Equatable {
    var appID: String
    var appSecret: String
    /// 自建弹弹play 兼容服务根地址(含令牌路径前缀)。空 = 官方 `api.dandanplay.net`。
    ///
    /// 放凭据文件而不是 `DanmakuDisplaySettings`(UserDefaults):自建服务的令牌写在 URL 路径里,
    /// 那是凭据,按「不在 UserDefaults 里存 token」处理。
    /// 默认值 `""` 让旧凭据文件(只有 appID / appSecret)仍能解码。
    var baseURL: String = ""

    var isComplete: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 指向自建服务时不校验弹弹play 签名,AppId / AppSecret 可以不填。
    var usesCustomServer: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 三项都空 = 什么都没配。
    var isEmpty: Bool {
        appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 声明了自定义解码器后成员初始化器不再合成,这里补回。
    init(appID: String, appSecret: String, baseURL: String = "") {
        self.appID = appID
        self.appSecret = appSecret
        self.baseURL = baseURL
    }

    /// 合成的解码不认默认值,缺 `baseURL` 键(旧凭据文件)会抛 `keyNotFound`,
    /// 逼用户重填 AppId / AppSecret —— 这里显式兜底。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appID = try container.decode(String.self, forKey: .appID)
        appSecret = try container.decode(String.self, forKey: .appSecret)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    }
}

/// 弹弹play HTTP 客户端:传输 + 签名 + 解码,无状态,凭据由调用方逐次传入(⛔ 不碰凭据存储)。
///
/// 认证用签名模式(§1):`X-AppId` / `X-Timestamp`(Unix 秒)/ `X-Signature`,AppSecret 不上网。
/// ⛔ 不用凭证模式(`X-AppSecret` 头直接带密钥),那是给服务端用的。
///
/// 地址从凭据的 `baseURL` 读(空 = 官方)。自建兼容服务不校验签名,签名头整体跳过 ——
/// 它鉴权看的是 URL 路径里的令牌,不是这套头(见 `docs/DANMU_API_FEASIBILITY.md` §2.5)。
struct DandanplayClient: Sendable {

    /// 可注入:签名测试要固定时间戳。
    typealias Clock = @Sendable () -> Date

    init(session: URLSession? = nil, now: @escaping Clock = { Date() }) {
        if let session {
            self.session = session
        } else {
            // 不落 URLSession 缓存、不收 cookie;弹幕缓存由 `DanmakuCommentCache` 自己管(§6)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
        self.now = now
    }

    private let session: URLSession
    private let now: Clock

    // MARK: - 接口

    /// §2
    func match(_ request: DandanplayMatchRequest, credentials: DandanplayCredentials) async throws
        -> DandanplayMatchResponse
    {
        try await fetch(.match(request), credentials: credentials)
    }

    /// §3。`anime` 至少 2 个字符;`episode` 是正整数或 `C1` / `S1` / `O1`;`tmdbIDType` 0 = 电视剧,1 = 电影。
    func searchEpisodes(
        anime: String?,
        episode: String?,
        tmdbID: Int? = nil,
        tmdbIDType: Int? = nil,
        credentials: DandanplayCredentials
    ) async throws -> DandanplaySearchEpisodesResponse {
        // `anime` 与 `tmdbId` 至少给一个(§3),⛔ 不发注定失败的请求
        guard anime?.isEmpty == false || tmdbID != nil else {
            throw DandanplayError.transport("search/episodes 需要 anime 或 tmdbId")
        }
        return try await fetch(
            .searchEpisodes(anime: anime, episode: episode, tmdbID: tmdbID, tmdbIDType: tmdbIDType),
            credentials: credentials)
    }

    /// §4
    func bangumi(animeID: Int64, credentials: DandanplayCredentials) async throws -> DandanplayBangumi {
        let response: DandanplayBangumiResponse =
            try await fetch(.bangumi(animeID: animeID), credentials: credentials)
        guard let bangumi = response.bangumi else {
            throw DandanplayError.api(
                code: response.errorCode, message: response.errorMessage ?? "作品不存在",
                detail: response.errorDetail)
        }
        return bangumi
    }

    /// §5。`withRelated` 恒为 true(官方推荐,含第三方关联弹幕)。
    func comments(
        episodeID: Int64,
        conversion: DandanplayEndpoint.ChineseConversion,
        credentials: DandanplayCredentials
    ) async throws -> [DandanplayComment] {
        let response: DandanplayCommentResponse = try await fetch(
            .comments(episodeID: episodeID, withRelated: true, chineseConversion: conversion),
            credentials: credentials)
        // 空库服务端给 `[]`;缺字段说明响应形状不对,不当 0 条
        guard let comments = response.comments else {
            throw DandanplayError.decoding(detail: "comment:缺少字段 comments")
        }
        return comments
    }

    // MARK: - 签名

    /// `base64(sha256(AppId + Timestamp + Path + AppSecret))`,区分大小写、无分隔符(§1)。
    static func signature(appID: String, timestamp: Int64, path: String, appSecret: String) -> String {
        let digest = SHA256.hash(data: Data("\(appID)\(timestamp)\(path)\(appSecret)".utf8))
        return Data(digest).base64EncodedString()
    }

    // MARK: - 传输

    private func fetch<T: Decodable & Sendable>(
        _ endpoint: DandanplayEndpoint,
        credentials: DandanplayCredentials
    ) async throws -> T {
        let data = try await send(endpoint, credentials: credentials)
        let decoded: T
        do {
            decoded = try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DandanplayError.decoding(detail: "\(endpoint.name):\(Self.describe(error))")
        }
        if let status = decoded as? any DandanplayStatusResponse, status.success == false {
            throw DandanplayError.api(
                code: status.errorCode, message: status.errorMessage, detail: status.errorDetail)
        }
        return decoded
    }

    /// 发一个请求。地址由凭据里的 `baseURL` 决定:空 = 官方,非空 = 自建兼容服务。
    ///
    /// 自建服务不校验弹弹play 签名(它只看 URL 里的令牌),⛔ 不发签名头也不要求 AppId / AppSecret;
    /// 官方服务两者都缺一不可。
    func send(_ endpoint: DandanplayEndpoint, credentials: DandanplayCredentials) async throws -> Data {
        guard let base = DandanplayBase(urlString: credentials.baseURL) else {
            throw DandanplayError.transport("弹幕服务地址无法解析,检查「设置 → 弹幕」里的服务地址")
        }
        guard let url = endpoint.url(base: base) else {
            throw DandanplayError.transport("接口地址构造失败(\(endpoint.name))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !credentials.usesCustomServer {
            let appID = credentials.appID.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = credentials.appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appID.isEmpty, !secret.isEmpty else { throw DandanplayError.credentialsMissing }
            let timestamp = Int64(now().timeIntervalSince1970)
            request.setValue(appID, forHTTPHeaderField: "X-AppId")
            request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
            request.setValue(
                Self.signature(appID: appID, timestamp: timestamp, path: endpoint.signaturePath, appSecret: secret),
                forHTTPHeaderField: "X-Signature")
        }
        if let body = try endpoint.body() {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            // `comment` 端点回 302 跳到弹幕加速服务(§5),URLSession 默认跟随
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DandanplayError.transport("响应不是 HTTP")
            }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401:
                throw DandanplayError.unauthorized
            case 403:
                throw DandanplayError.forbidden(reason: http.value(forHTTPHeaderField: "X-Error-Message"))
            default:
                throw DandanplayError.server(statusCode: http.statusCode)
            }
        } catch let error as DandanplayError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // ⛔ 不 `String(describing:)`:URLError 的 userInfo 带完整 URL(含搜索词)
            let nsError = error as NSError
            throw DandanplayError.transport(
                SecretRedactor.redacted("\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)"))
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
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
    }
}
