import CryptoKit
import Foundation

/// 弹弹play 开放平台的应用凭据(开发者中心审核通过后发放,`docs/DANDANPLAY_API.md` §1)。
///
/// 由用户在设置页自填,存凭据文件(`CredentialStore`),⛔ 不进仓库、不进 UserDefaults。
struct DandanplayCredentials: Codable, Sendable, Equatable {
    var appID: String
    var appSecret: String

    /// 两项都填了才算可用(去掉首尾空白后判断)。
    var isComplete: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 弹弹play 的 HTTP 客户端(纯传输 + 签名 + 解码;⛔ 不碰凭据存储)。
///
/// 与 `TMDBClient` 同一分工:凭据由调用方逐次传入,客户端无状态(`Sendable` struct)。
///
/// ## 认证:签名模式(§1)
///
/// ```
/// X-AppId:     {AppId}
/// X-Timestamp: {Unix 秒}
/// X-Signature: base64(sha256(AppId + Timestamp + Path + AppSecret))
/// ```
///
/// 官方给客户端应用推荐签名模式 —— AppSecret 本身不上网。⛔ 不用「凭证模式」
/// (`X-AppSecret` 头直接带密钥):那是给能保护密钥的服务端用的。
struct DandanplayClient: Sendable {

    /// 当前时间(秒)。可注入:签名测试要固定时间戳。
    typealias Clock = @Sendable () -> Date

    init(session: URLSession? = nil, now: @escaping Clock = { Date() }) {
        if let session {
            self.session = session
        } else {
            // 与 TMDB 同一处置:不落 URLSession 缓存、不收 cookie。
            // 弹幕的缓存由 `DanmakuCommentCache` 按官方建议的时长自己管(§6)。
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

    /// 按文件名匹配节目(§2)。
    func match(_ request: DandanplayMatchRequest, credentials: DandanplayCredentials) async throws
        -> DandanplayMatchResponse
    {
        try await fetch(.match(request), credentials: credentials)
    }

    /// 搜剧集(§3)。按作品名与 / 或 TMDB ID。
    ///
    /// - `anime`:作品名(至少 2 个字符),不知道就传 nil
    /// - `episode`:集号字符串(正整数或 `C1` / `S1` / `O1`),不知道就传 nil
    /// - `tmdbID` + `tmdbIDType`:语言无关的作品身份;`tmdbIDType` 0 = 电视剧,1 = 电影
    func searchEpisodes(
        anime: String?,
        episode: String?,
        tmdbID: Int? = nil,
        tmdbIDType: Int? = nil,
        credentials: DandanplayCredentials
    ) async throws -> DandanplaySearchEpisodesResponse {
        // `anime` 与 `tmdbId` 至少给一个(§3):都不给是调用方的错,⛔ 不发注定失败的请求
        guard anime?.isEmpty == false || tmdbID != nil else {
            throw DandanplayError.transport("search/episodes 需要 anime 或 tmdbId")
        }
        return try await fetch(
            .searchEpisodes(anime: anime, episode: episode, tmdbID: tmdbID, tmdbIDType: tmdbIDType),
            credentials: credentials)
    }

    /// 作品详情里的剧集列表(§4)。
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

    /// 一个弹幕库的全部弹幕(§5)。`withRelated` 恒为 true(官方推荐,含第三方关联弹幕)。
    func comments(
        episodeID: Int64,
        conversion: DandanplayEndpoint.ChineseConversion,
        credentials: DandanplayCredentials
    ) async throws -> [DandanplayComment] {
        let response: DandanplayCommentResponse = try await fetch(
            .comments(episodeID: episodeID, withRelated: true, chineseConversion: conversion),
            credentials: credentials)
        // `comments` 缺失 ≠ 0 条:规格里它可空,但「空库」服务端会给 `[]`。缺字段说明响应形状不对
        guard let comments = response.comments else {
            throw DandanplayError.decoding(detail: "comment:缺少字段 comments")
        }
        return comments
    }

    // MARK: - 签名

    /// `base64(sha256(AppId + Timestamp + Path + AppSecret))`(§1,区分大小写、无分隔符)。
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

    func send(_ endpoint: DandanplayEndpoint, credentials: DandanplayCredentials) async throws -> Data {
        let appID = credentials.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = credentials.appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !secret.isEmpty else { throw DandanplayError.credentialsMissing }
        guard let url = endpoint.url else {
            throw DandanplayError.transport("接口地址构造失败(\(endpoint.name))")
        }
        let timestamp = Int64(now().timeIntervalSince1970)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(appID, forHTTPHeaderField: "X-AppId")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(
            Self.signature(appID: appID, timestamp: timestamp, path: endpoint.signaturePath, appSecret: secret),
            forHTTPHeaderField: "X-Signature")
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
