import Foundation

/// 夸克 TV 端的 HTTP 客户端:纯传输 + 签名 + 解码,**不含登录状态机、不碰凭据存储**
/// (凭据的生命周期在 `QuarkConnection`)。
///
/// 端点与参数见 `docs/QUARK_API.md` §2 - §6。两个硬约定:
/// - 每个业务请求都要签名(`x-pan-tm` / `x-pan-token` / 查询串里的 `req_id`),缺一个就回 `errno 10001`;
/// - 错误码在 HTTP 200/400 的响应体里(`status` / `errno`),⛔ 不能只看状态码。
struct QuarkAPIClient: Sendable {

    init(session: URLSession? = nil, limiter: QuarkRateLimiter = QuarkRateLimiter()) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            // 凭据在查询串与请求头里,⛔ 不让 URLSession 维护 cookie jar
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
        self.limiter = limiter
    }

    private let session: URLSession
    private let limiter: QuarkRateLimiter

    // MARK: - 扫码登录(§4)

    func authorize(deviceID: String) async throws -> QuarkQRCodeSession {
        let response: QuarkAuthorizeResponse = try await send(
            .authorize, accessToken: nil, deviceID: deviceID)
        guard let session = response.session else {
            throw QuarkError.decoding(
                endpoint: QuarkEndpoint.authorize.name, detail: "响应里没有 qr_data / query_token")
        }
        return session
    }

    /// 用 `query_token` 换授权码。
    ///
    /// ⚠️ 这里**没有**独立的状态查询端点:用户没确认时服务端回 `errno 11003 用户未确认授权`
    /// (2026-11-20 实测)。调用方据此判断「继续等」,不是失败。
    func code(queryToken: String, deviceID: String) async throws -> String {
        let endpoint = QuarkEndpoint.code(queryToken: queryToken)
        let response: QuarkCodeResponse = try await send(
            endpoint, accessToken: nil, deviceID: deviceID)
        guard let code = response.code, !code.isEmpty else {
            throw QuarkError.decoding(endpoint: endpoint.name, detail: "响应里没有 code")
        }
        return code
    }

    /// 换 token(首次登录用 `code`,刷新用 `refresh_token`)。走第三方主机 `api.extscreen.com`(§4)。
    ///
    /// - Returns: 新的 `access_token` / `refresh_token` 对。⚠️ `refresh_token` 会被**轮换**,新值必须落盘(§3)。
    ///
    /// ⛔ 外层 `code == 200` 只表示受理:内层 `data.status` / `data.errno` 才是业务结论。
    func exchangeToken(
        deviceID: String,
        code: String?,
        refreshToken: String?
    ) async throws -> (access: String, refresh: String) {
        guard code != nil || refreshToken != nil else {
            throw QuarkError.invalidRequest("换 token 要 code 或 refresh_token 之一")
        }
        try await limiter.acquire()
        var components = URLComponents()
        components.scheme = "https"
        components.host = QuarkEndpoint.codeHost
        components.path = QuarkEndpoint.codeBasePath + "/token"
        guard let url = components.url else {
            throw QuarkError.transport("换 token 的地址构造失败")
        }

        var body: [String: String] = [:]
        for item in QuarkDeviceFingerprint.queryItems(deviceID: deviceID) {
            body[item.name] = item.value
        }
        // `req_id` 在这条路径上不签名(第三方服务只当它是个请求 id),仍按同一算法算
        body["req_id"] = QuarkSigner.md5Hex(
            deviceID + String(QuarkSigner.nowMilliseconds()))
        if let code {
            body["code"] = code
        } else if let refreshToken {
            body["refresh_token"] = refreshToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(QuarkDeviceFingerprint.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw QuarkError.transport("换 token 的请求体编码失败")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw QuarkError.transport("换 token 的响应不是 HTTP")
            }
            data = responseData
            http = response
        } catch let error as QuarkError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QuarkError.transport(Self.describeTransport(error))
        }

        let response: QuarkTokenExchangeResponse
        do {
            response = try JSONDecoder().decode(QuarkTokenExchangeResponse.self, from: data)
        } catch {
            throw QuarkError.decoding(
                endpoint: "extscreen/token", detail: "HTTP \(http.statusCode),响应不是预期的 JSON")
        }
        guard response.code == 200 else {
            throw QuarkError.tokenExchange(code: response.code ?? http.statusCode, message: response.message)
        }
        guard let payload = response.data else {
            throw QuarkError.decoding(endpoint: "extscreen/token", detail: "响应里没有 data")
        }
        if !payload.envelope.isSuccess {
            // 两条要分开处置的:11004 授权码无效 / 11000 刷新令牌无效 —— 都只能重新扫码(§8)
            switch payload.envelope.effectiveErrno {
            case QuarkCode.authorizationCodeInvalid: throw QuarkError.authorizationCodeInvalid
            case QuarkCode.refreshTokenInvalid: throw QuarkError.refreshTokenInvalid
            default:
                throw QuarkError.server(
                    code: payload.envelope.effectiveErrno,
                    message: payload.envelope.errorMessage)
            }
        }
        guard let tokens = payload.tokens else {
            // `refresh_token` 为空在参考实现里就是失败(§4)
            throw QuarkError.decoding(endpoint: "extscreen/token", detail: "响应里没有可用的令牌对")
        }
        return tokens
    }

    // MARK: - 登录态(§7)

    /// 只为验证 `access_token` 是否有效。⚠️ 与 115 不同,这里没有会踢设备的探活端点(§7)。
    func userInfo(accessToken: String, deviceID: String) async throws -> QuarkAccount {
        let response: QuarkUserInfoResponse = try await send(
            .userInfo, accessToken: accessToken, deviceID: deviceID)
        return response.account
    }

    // MARK: - 目录(§5)

    /// 列一页。⛔ 不做自动翻页:浏览页按需取(滚到底再取下一页),夸克按次记账且要串行(§5、§10)。
    ///
    /// 「还有没有下一页」的判据(`docs/QUARK_API.md` §5):
    /// - 总数给了:已取满就不再有;
    /// - 总数没给:退回「本页不满即到底」。
    /// - ⚠️ 不论哪一种,+ 本页为空一律停:参考实现 quarkDav 就是这么兜底,防总数异常时死循环。
    func list(
        parentFid: String,
        accessToken: String,
        deviceID: String,
        pageIndex: Int,
        pageSize: Int = QuarkPolicy.pageSize
    ) async throws -> QuarkDirectoryPage {
        let response: QuarkFileListResponse = try await send(
            .list(parentFid: parentFid, pageIndex: pageIndex, pageSize: pageSize),
            accessToken: accessToken,
            deviceID: deviceID)
        let entries = response.files
        let answeredIndex = pageIndex
        return QuarkDirectoryPage(
            files: entries,
            pageIndex: answeredIndex,
            pageSize: pageSize,
            totalCount: response.totalCount,
            hasMore: Self.hasMore(
                fetched: entries.count,
                pageIndex: answeredIndex,
                pageSize: pageSize,
                totalCount: response.totalCount)
        )
    }

    /// - Parameters:
    ///   - fetched: 本页解码出来的条数(缺 `fid` / `filename` 的条目已被丢掉)
    ///   - pageIndex: 服务端认的 `page_index`
    ///
    /// ⚠️ 推进量用**服务端口径**(`(pageIndex + 1) * pageSize`),⛔ 不用 `fetched`:
    /// 解码丢条目会让它少于服务端实际推进的条数,用它算会多翻一页空请求。
    static func hasMore(
        fetched: Int,
        pageIndex: Int,
        pageSize: Int,
        totalCount: Int?
    ) -> Bool {
        guard fetched > 0 else { return false }
        guard let totalCount else { return fetched >= pageSize }
        return (pageIndex + 1) * pageSize < totalCount
    }

    // MARK: - 取直链(§6.1)

    /// 取原文件直链。`download_url` 原样交给内核:普通 https,内核自己跟 302、自己发 `Range`。
    func download(fid: String, accessToken: String, deviceID: String) async throws -> QuarkDownloadLink {
        let endpoint = QuarkEndpoint.download(fid: fid)
        let response: QuarkDownloadResponse = try await send(
            endpoint, accessToken: accessToken, deviceID: deviceID)
        guard let raw = response.downloadURL, !raw.isEmpty else {
            throw QuarkError.playbackUnsupported(
                "夸克没有给这个文件返回播放地址(可能是转码中或文件已失效)。")
        }
        // ⛔ 不做 `URLComponents` 往返(会改签名参数);只做 `URL(string:)` 一次解析
        guard let url = URL(string: raw) else {
            throw QuarkError.decoding(
                endpoint: endpoint.name, detail: "download_url 无法解析成 URL")
        }
        return QuarkDownloadLink(
            url: url,
            sizeBytes: response.size.map { UInt64(max(0, $0)) },
            // TV 端 CDN 直链自带签名,参考实现都不挂头(§6.1)。⛔ 不预先塞一堆头
            headers: [:]
        )
    }

    // MARK: - 传输

    func send<T: Decodable & Sendable>(
        _ endpoint: QuarkEndpoint,
        accessToken: String?,
        deviceID: String
    ) async throws -> T {
        try await limiter.acquire()
        let signature = QuarkSigner.sign(
            method: endpoint.method,
            path: endpoint.path,
            deviceID: deviceID,
            milliseconds: QuarkSigner.nowMilliseconds()
        )
        guard let url = Self.url(
            endpoint, signature: signature, accessToken: accessToken, deviceID: deviceID)
        else {
            throw QuarkError.transport("接口地址构造失败(\(endpoint.name))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        // ⚠️ 设备指纹与 UA 是服务端认「TV 客户端」的依据(§1),⛔ 不要换成 Mac Safari
        request.setValue(QuarkDeviceFingerprint.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(signature.timestamp, forHTTPHeaderField: "x-pan-tm")
        request.setValue(signature.panToken, forHTTPHeaderField: "x-pan-token")
        request.setValue(QuarkEndpoint.clientID, forHTTPHeaderField: "x-pan-client-id")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw QuarkError.transport("响应不是 HTTP")
            }
            data = responseData
            http = response
        } catch let error as QuarkError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QuarkError.transport(Self.describeTransport(error))
        }

        // 夸克的业务错误也在 400 里,所以先解信封再判状态码
        try Self.validate(data, endpoint: endpoint, http: http)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw QuarkError.decoding(
                endpoint: endpoint.name, detail: Self.describe(error))
        }
    }

    /// 查询串:手拼而不是 `URLComponents.queryItems`。
    ///
    /// ⚠️ 与百度 / 115 同一个坑:签名常量与 `fid` 里出现 `+` `/` `=` 时,默认的 queryItems
    /// 编码规则与服务端期望的不一致。这里只保留 unreserved 字符,`=` 与 `+` 都会被编掉。
    static func url(
        _ endpoint: QuarkEndpoint,
        signature: QuarkSignature,
        accessToken: String?,
        deviceID: String
    ) -> URL? {
        var items: [(name: String, value: String)] = [
            ("req_id", signature.requestID),
            ("access_token", accessToken ?? ""),
        ]
        items.append(contentsOf: QuarkDeviceFingerprint.queryItems(deviceID: deviceID))
        items.append(contentsOf: endpoint.queryItems)

        let query = items.compactMap { item -> String? in
            guard let name = QuarkEndpoint.encode(item.name),
                  let value = QuarkEndpoint.encode(item.value) else { return nil }
            return "\(name)=\(value)"
        }
        .joined(separator: "&")

        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.path = endpoint.path
        if !query.isEmpty { components.percentEncodedQuery = query }
        return components.url
    }

    /// 信封判定(`docs/QUARK_API.md` §3、§8)。
    ///
    /// 只有「二维码过期」在这里单独成档(它是用户唯一需要换一张图的信号)。
    /// 其余非零 `errno` 一律原样带码:`11001` 要刷新、`11003` 要继续等,
    /// 语境只有上层知道(`QuarkConnection`),⛔ 这层不替它决定。
    static func validate(_ data: Data, endpoint: QuarkEndpoint, http: HTTPURLResponse) throws {
        guard let envelope = try? JSONDecoder().decode(QuarkEnvelope.self, from: data) else {
            guard (200..<300).contains(http.statusCode) else {
                throw QuarkError.transport("HTTP \(http.statusCode)")
            }
            return
        }
        if envelope.isSuccess { return }
        let code = envelope.effectiveErrno
        switch code {
        case QuarkCode.qrCodeExpired:
            throw QuarkError.qrCodeExpired
        case QuarkCode.tokenInvalid, QuarkCode.signatureInvalid, QuarkCode.authorizationPending,
             QuarkCode.parameterInvalid:
            // 11001 交给 `QuarkConnection` 刷新后重试;11003 是扫码轮询的正常等待态;
            // 10001 是签名 / 公参被拒(**不是** token 过期,实测);14001 是参数缺失。
            // 三者都原样带码出去,由上层按语境处置。
            throw QuarkError.server(code: code, message: envelope.errorMessage)
        default:
            // 表外的码原样带出,⛔ 不编猜测文案
            throw QuarkError.server(
                code: code == 0 ? http.statusCode : code,
                message: envelope.errorMessage)
        }
    }

    /// ⛔ 不用 `String(describing:)`:`URLError` 的 userInfo 带完整 URL(查询串里有 access_token)。
    static func describeTransport(_ error: any Error) -> String {
        let nsError = error as NSError
        return SecretRedactor.redacted(
            "\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)")
    }

    /// `DecodingError` 的可读描述,点名到字段。⛔ 只带键名不带值。
    static func describe(_ error: any Error) -> String {
        switch error {
        case let decoding as DecodingError:
            switch decoding {
            case .keyNotFound(let key, _):
                return "缺少字段 \(key.stringValue)"
            case .typeMismatch(let type, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "字段 \(path) 类型不是 \(type)"
            case .valueNotFound(let type, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "字段 \(path) 为 null(期望 \(type))"
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

/// 串行限速器 + 频控冷却(`docs/QUARK_API.md` §5、§10:串行、两次请求间隔 ≥ 500ms)。
///
/// 两份参考实现都没有退避逻辑,本项目保守处理:⛔ 不并发打夸克,⛔ 不把间隔调到 500ms 以下。
/// 命中一次频控后进入冷却:冷却期内 `acquire()` 直接抛 `rateLimited`,**一个请求都不发**。
actor QuarkRateLimiter {
    init(minimumInterval: Duration = QuarkPolicy.minimumRequestInterval) {
        self.minimumInterval = minimumInterval
    }

    private let minimumInterval: Duration
    private var lastRequest: ContinuousClock.Instant?
    /// 冷却截止点。`nil` = 没在冷却。
    private var coolDownUntil: ContinuousClock.Instant?

    func acquire() async throws {
        let now = ContinuousClock.now
        if let until = coolDownUntil {
            let remaining = now.duration(to: until)
            if remaining > .zero {
                throw QuarkError.rateLimited(
                    retryAfter: TimeInterval(remaining.components.seconds)
                        + TimeInterval(remaining.components.attoseconds) / 1e18)
            }
            coolDownUntil = nil
        }
        if let last = lastRequest {
            let elapsed = now - last
            if elapsed < minimumInterval {
                try await Task.sleep(for: minimumInterval - elapsed)
            }
        }
        lastRequest = ContinuousClock.now
    }

    /// 记一次频控。冷却期内所有请求直接失败,不再外发。
    func noteRateLimited(for duration: Duration = QuarkPolicy.rateLimitCoolDown) {
        let until = ContinuousClock.now.advanced(by: duration)
        if let current = coolDownUntil, current > until { return }
        coolDownUntil = until
        // 冷却结束后第一发也要满足最小间隔,不趁刚恢复就连打
        lastRequest = nil
    }

    /// 当前冷却剩余秒数,`nil` = 不在冷却中。
    var remainingCoolDown: TimeInterval? {
        guard let until = coolDownUntil else { return nil }
        let remaining = ContinuousClock.now.duration(to: until)
        return remaining > .zero ? TimeInterval(remaining.components.seconds) : nil
    }
}
