import Foundation

/// 百度网盘的 HTTP 客户端(纯传输 + 解码,⛔ 不含授权状态机、不碰凭据)。
///
/// 与 `EmbyAPIClient` 的分工一致:查询串拼装与错误映射在这里,
/// 「什么时候刷新 token」「什么时候重新授权」在 `BaiduPanConnection`。
///
/// ## 错误映射(文档 §4.4 / §4.5 的错误码表)
///
/// 百度把业务错误码放在 HTTP 200 的响应体里(`errno`),所以**不能只看状态码**:
/// 每个响应都要先读 `errno`,`0` 才算成功。失败时抛 `BaiduPanError.server`,
/// 由上层按 `BaiduPanErrno.requiresTokenRefresh` / 可直接重试的表处置。
struct BaiduPanAPIClient: Sendable {

    /// ⚠️ 用独立的会话:`access_token` 会出现在 URL 上,而 `URLSession` 的
    /// 缓存 / cookie 会把带凭据的 URL 落盘。这里一律关掉,并且不吃任何缓存
    /// —— 列表与元信息都是「刚改过就要看到」的东西。
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

    /// 一次列表最多取多少条。⛔ 别调大:未审核应用的频率限制极低(§2.3),
    /// `/apps/{appname}` 下的片子也远不到这个量级。
    static let pageSize = 200
    /// 翻页上限。防御性的:万一服务端忽略 `start` 一直返满页,
    /// 也不能变成无限循环 —— 5 页 × 200 条已经远超自用场景。
    static let maxPages = 5

    // MARK: - 授权

    func deviceCode(clientID: String) async throws -> BaiduPanDeviceCode {
        let endpoint = BaiduPanEndpoint.deviceCode(
            clientID: clientID, scope: BaiduPanAppCredentials.scope)
        let data = try await send(endpoint)
        let response: BaiduPanDeviceCodeResponse = try decode(data, endpoint: endpoint)
        return response.deviceCodeValue
    }

    /// 用设备码换 token(`grant_type=device_token`)。轮询时调用。
    func token(
        deviceCode: String,
        clientID: String,
        clientSecret: String,
        now: Date = Date()
    ) async throws -> BaiduPanTokenBundle {
        let endpoint = BaiduPanEndpoint.deviceToken(
            deviceCode: deviceCode, clientID: clientID, clientSecret: clientSecret)
        let data = try await send(endpoint)
        let response: BaiduPanTokenResponse = try decode(data, endpoint: endpoint)
        guard let bundle = response.bundle(now: now) else {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name, detail: "响应里没有 refresh_token")
        }
        return bundle
    }

    /// 刷新 token。⚠️ 调用方必须保证**单飞**(`refresh_token` 只能用一次,§3.4)。
    func refresh(
        refreshToken: String,
        clientID: String,
        clientSecret: String,
        now: Date = Date()
    ) async throws -> BaiduPanTokenBundle {
        let endpoint = BaiduPanEndpoint.refreshToken(
            refreshToken: refreshToken, clientID: clientID, clientSecret: clientSecret)
        let data = try await send(endpoint)
        let response: BaiduPanTokenResponse = try decode(data, endpoint: endpoint)
        guard let bundle = response.bundle(now: now) else {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name, detail: "刷新响应里没有新的 refresh_token")
        }
        return bundle
    }

    func accountInfo(accessToken: String) async throws -> BaiduPanAccount {
        let endpoint = BaiduPanEndpoint.userInfo(accessToken: accessToken)
        let data = try await send(endpoint)
        let response: BaiduPanUserInfoResponse = try decode(data, endpoint: endpoint)
        return response.account
    }

    // MARK: - 目录与元信息

    /// 列一个目录。自动翻页,直到返回不满一页或到 `maxPages`。
    func list(directory: String, accessToken: String) async throws -> [BaiduPanFile] {
        var files: [BaiduPanFile] = []
        for page in 0..<Self.maxPages {
            let endpoint = BaiduPanEndpoint.fileList(
                accessToken: accessToken,
                directory: directory,
                start: page * Self.pageSize,
                limit: Self.pageSize
            )
            let data = try await send(endpoint)
            let response: BaiduPanListResponse = try decode(data, endpoint: endpoint)
            let entries = (response.list ?? []).compactMap(\.file)
            files.append(contentsOf: entries)
            // 不满一页 = 到底了(`has_more` 是 `listall` 的字段,`list` 没有)
            if entries.count < Self.pageSize { break }
        }
        return files
    }

    /// 取单条文件的元信息(**含 `dlink`**,8 小时有效)。
    ///
    /// ⚠️ 走 `multimedia?method=filemetas` 而**不是** `file?method=meta`:
    /// 后者 2026-10-10 用真实应用实测**不给 `dlink`、也不给 `errno`**
    /// (见 `BaiduPanEndpoint.fileMeta` 的注释)。用 `fs_id` 查而不是 `path`。
    func meta(fsID: UInt64, accessToken: String) async throws -> BaiduPanFileMeta {
        let endpoint = BaiduPanEndpoint.fileMeta(accessToken: accessToken, fsID: fsID)
        let data = try await send(endpoint)
        let response: BaiduPanMetaResponse = try decode(data, endpoint: endpoint)
        // `errno != 0` 已被 `validate` 拦下(带 `errmsg`),走到这里 `errno` 必为 0,
        // 空列表就是「这个 fs_id 没有对应文件」。
        guard let entry = response.list?.first else {
            throw BaiduPanError.server(errno: BaiduPanErrno.notFound, message: response.showMessage)
        }
        return entry
    }

    // MARK: - 播放流探测

    /// 起播前探一次 `method=streaming`(`nom3u8=1`,只要状态)。
    ///
    /// - Returns: `nil` 表示可以播;非 nil 是要展示给用户的失败。
    ///   ⚠️ `133`(非会员要看广告)会**先带 `adToken` 重试一次**(§4.4 的处置),
    ///   仍失败才算失败 —— 直接把 133 甩给用户等于不给机会。
    func probeStreaming(
        path: String,
        type: BaiduPanStreamType,
        accessToken: String
    ) async throws -> BaiduPanError? {
        let first = try await streamingStatus(
            path: path, type: type, accessToken: accessToken, adToken: nil)
        guard let errno = first.errno, errno != 0 else { return nil }
        if errno == BaiduPanErrno.needAd, let adToken = first.adToken {
            let retry = try await streamingStatus(
                path: path, type: type, accessToken: accessToken, adToken: adToken)
            if retry.errno == 0 { return nil }
            return .server(errno: retry.errno ?? errno, message: retry.showMessage)
        }
        return .server(errno: errno, message: first.showMessage)
    }

    func streamingStatus(
        path: String,
        type: BaiduPanStreamType,
        accessToken: String,
        adToken: String?
    ) async throws -> BaiduPanErrnoEnvelope {
        let endpoint = BaiduPanEndpoint.streaming(
            accessToken: accessToken, path: path, type: type,
            probeOnly: true, adToken: adToken)
        let data = try await send(endpoint)
        guard let envelope = try? JSONDecoder().decode(BaiduPanErrnoEnvelope.self, from: data),
              envelope.errno != nil else {
            throw BaiduPanError.decoding(endpoint: endpoint.name, detail: "响应不是 JSON 状态")
        }
        return envelope
    }

    // MARK: - 传输与解码

    /// 发一次请求,返回响应体。**只做传输层校验**(HTTP 状态、是否 HTTP 响应),
    /// 业务错误码交给 `decode`。
    func send(_ endpoint: BaiduPanEndpoint) async throws -> Data {
        guard let url = endpoint.url else {
            throw BaiduPanError.configuration("接口地址构造失败(\(endpoint.name))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        for (name, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BaiduPanError.transport("响应不是 HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw BaiduPanError.transport("HTTP \(http.statusCode)")
            }
            try validate(data, endpoint: endpoint)
            return data
        } catch let error as BaiduPanError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // ⛔ 绝不 `String(describing: error)`:`URLError` 的 userInfo 里带
            // `NSURLErrorFailingURLStringErrorKey`,而我们的 URL 查询串上有
            // `access_token`(ARCHITECTURE.md 8.1)。取域 + 码 + 描述再过脱敏。
            let nsError = error as NSError
            throw BaiduPanError.transport(
                SecretRedactor.redacted("\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)"))
        }
    }

    /// 解码。解码失败只带端点名与解码器描述,⛔ **不带响应体**
    /// (响应里可能有 token)。
    func decode<T: Decodable & Sendable>(_ data: Data, endpoint: BaiduPanEndpoint) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name, detail: Self.describe(error, data: data))
        }
    }

    /// 业务错误码与 OAuth 错误的统一识别。
    ///
    /// 顺序有意如此:网盘接口**永远**带 `errno`(成功为 0),先按它判;
    /// OAuth 成功响应没有 `errno`,失败时给的是 `error`。
    private func validate(_ data: Data, endpoint: BaiduPanEndpoint) throws {
        if let envelope = try? JSONDecoder().decode(BaiduPanErrnoEnvelope.self, from: data),
           let errno = envelope.errno, errno != 0 {
            throw BaiduPanError.server(errno: errno, message: envelope.showMessage)
        }
        if let oauth = try? JSONDecoder().decode(BaiduPanOAuthErrorResponse.self, from: data) {
            // ⛔ 不在这里折成 `notAuthorized`:设备码轮询时「用户还没确认」
            // 也是一个 OAuth 错误响应,必须让上层看得出是**哪个**码
            // (见 `BaiduPanError.isFatalOAuthCode`)。
            throw BaiduPanError.oauth(code: oauth.error, message: oauth.errorDescription)
        }
    }

    /// `DecodingError` 的可读描述。`keyNotFound` / `typeMismatch` 都点名到字段,
    /// 排障时能直接看出是哪个字段对不上 —— 这正是「核实字段名」的反馈回路。
    ///
    /// 后面额外附上**响应顶层的键名**:只说「缺少字段 errno」是没法定位的
    /// (2026-10-10 那次事故:百度换了响应形状,报错只说缺 `errno`,得写脚本重打一次
    /// 接口才知道它改成了什么)。键名是**非敏感**的 —— 值的部分一个字都不带
    /// (响应里可能有 token / dlink 签名,ARCHITECTURE.md 8.1)。
    private static func describe(_ error: any Error, data: Data) -> String {
        let base: String
        switch error {
        case let decoding as DecodingError:
            switch decoding {
            case .keyNotFound(let key, _):
                base = "缺少字段 \(key.stringValue)"
            case .typeMismatch(let type, let context):
                base = "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 类型不是 \(type)"
            case .valueNotFound(let type, let context):
                base = "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 为 null(期望 \(type))"
            case .dataCorrupted(let context):
                base = "响应不是合法 JSON(\(context.debugDescription))"
            @unknown default:
                base = "无法解析"
            }
        default:
            return "\(error)"
        }
        guard let keys = topLevelKeys(in: data), !keys.isEmpty else { return base }
        return "\(base);响应顶层键:\(keys.joined(separator: ","))"
    }

    /// 响应 JSON 的顶层键名(最多 12 个,超了截断 —— 这条只进错误文案)。
    /// 不是 JSON 对象(数组 / 文本 / HTML)时返回 nil。
    static func topLevelKeys(in data: Data) -> [String]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        return object.keys.sorted().prefix(12).map { $0 }
    }
}
