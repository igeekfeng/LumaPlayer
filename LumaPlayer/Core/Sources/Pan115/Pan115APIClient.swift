import Foundation

/// 115 的 HTTP 客户端:纯传输 + 解码 + 加解密,**不含登录状态机、不碰凭据存储**
/// (凭据的生命周期在 `Pan115Connection`)。
///
/// 115 的错误码在 HTTP 200 的响应体里(`state: 0` + `errno` / `code`),⛔ 不能只看状态码。
/// 端点与参数见 `docs/PAN115_API.md` §2 - §4。
struct Pan115APIClient: Sendable {

    init(session: URLSession? = nil, limiter: Pan115RateLimiter = Pan115RateLimiter()) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            // Cookie 由我们自己从 `Pan115Credential` 拼,⛔ 不让 URLSession 维护 cookie jar
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
        self.limiter = limiter
    }

    private let session: URLSession
    private let limiter: Pan115RateLimiter

    /// `list()` 自动翻页时的一页条数。115 的硬上限是 1150(`docs/PAN115_API.md` §3),取 1000 留余量。
    /// ⚠️ 只服务「必须一次拿整层」的 `list()`;浏览页走 `listPage(...,limit:)`,
    /// 条数由 `FileSourceViewModel.browsePageSize` 给,⛔ 不用这个值。
    static let pageSize = 1000
    /// `list()` 最多翻几页:防御服务端忽略 `offset` 一直返满页导致死循环。
    static let maxPages = 5

    // MARK: - 扫码登录(§2.2)

    func qrCodeToken(app: String = "web") async throws -> Pan115QRCodeSession {
        let endpoint = Pan115Endpoint.qrCodeToken(app: app)
        let data = try await send(endpoint).data
        let response: Pan115QRCodeTokenResponse = try decode(data, endpoint: endpoint)
        guard let session = response.data?.session else {
            throw Pan115Error.decoding(
                endpoint: endpoint.name, detail: "响应里没有 uid / time / sign / qrcode")
        }
        return session
    }

    /// ⚠️ 这个接口是长轮询:115 那边会把请求挂住,直到状态变化或超时。
    func qrCodeStatus(_ session: Pan115QRCodeSession, now: Int = Int(Date().timeIntervalSince1970))
        async throws -> Pan115QRCodeStatus
    {
        let endpoint = Pan115Endpoint.qrCodeStatus(
            uid: session.uid, time: session.time, sign: session.sign, now: now)
        let data = try await send(endpoint).data
        let response: Pan115QRCodeStatusResponse = try decode(data, endpoint: endpoint)
        guard let status = response.data?.value else {
            throw Pan115Error.decoding(endpoint: endpoint.name, detail: "响应里没有 status")
        }
        return status
    }

    /// 换 Cookie 四件套。
    ///
    /// ⚠️ `account` 用的是 **token 响应里的 `uid`**,不是 Cookie 里的 `UID`(§2.2 第 4 步)。
    func qrCodeLogin(_ session: Pan115QRCodeSession, app: String = "web") async throws
        -> Pan115Credential
    {
        let endpoint = Pan115Endpoint.qrCodeLogin(app: app, account: session.uid)
        let data = try await send(endpoint).data
        let response: Pan115QRCodeLoginResponse = try decode(data, endpoint: endpoint)
        guard let credential = response.data?.credential else {
            throw Pan115Error.decoding(
                endpoint: endpoint.name, detail: "响应里没有完整的 cookie 四件套")
        }
        return credential
    }

    // MARK: - 登录态(§2.3)

    /// 用户信息。⛔ 不要为此加 `passportapi.115.com/.../check/sso` 那种探活 —— 它会踢掉同设备其它 Cookie。
    func account(_ credential: Pan115Credential) async throws -> Pan115Account {
        let endpoint = Pan115Endpoint.userInfo(now: Self.milliseconds())
        let data = try await send(endpoint, credential: credential).data
        let response: Pan115UserInfoResponse = try decode(data, endpoint: endpoint)
        guard let account = response.data?.account else {
            throw Pan115Error.decoding(endpoint: endpoint.name, detail: "响应里没有用户信息")
        }
        return account
    }

    // MARK: - 目录(§3)

    /// 列一页。`cid` 传 `"0"` 是根目录。
    ///
    /// ⛔ **单页**返回,不做自动翻页:浏览页要按需取(滚到底再取下一页),
    /// 而 115 的请求是串行的、两次之间至少隔 500 ms(§6),一次把整个目录拉完既慢又烧风控面。
    ///
    /// `count` 是**该目录的总条目数**(官方 SDK 的注释是「当前目录文件数量」;
    /// `get_file_count` 更是用 `page_size=1` 只取一条却从 `count` 读出总数),
    /// 所以「还有没有下一页」可以精确判断,⛔ 不必靠「不满页」猜。
    func listPage(
        cid: String,
        credential: Pan115Credential,
        offset: Int,
        limit: Int
    ) async throws -> Pan115DirectoryPage {
        let endpoint = Pan115Endpoint.fileList(cid: cid, offset: offset, limit: limit)
        let data = try await send(endpoint, credential: credential).data
        let response: Pan115FileListResponse = try decode(data, endpoint: endpoint)
        let entries = response.entries
        // 服务端回显的 `offset` 是它认的位置(§3):aps 接口的文档明写 offset 越界会
        // 「相当于 offset=0,从头开始」,自行累加步长会静默回绕成死循环。
        //
        // ⚠️ **服务端没回显 `offset` 时,⛔ 不能当成「它不认」**:
        // 那是「无法证伪」而不是「证伪」,当成不认会让浏览页永远停在第一页
        // (目录明明有 3000 条,界面只显示 1000 条,⛔ 还不报错)。
        // ⇒ 回绕的防护靠**内容重复**那道闸(见 `FileSourceDirectoryState` 的累计去重),
        // 这里只判「回显了但与请求不符」这一种确凿的情况。
        let acknowledgedOffset = response.offset ?? offset
        let isOffsetHonored = response.offset == nil || acknowledgedOffset == offset
        let totalCount = response.count
        return Pan115DirectoryPage(
            entries: entries,
            offset: acknowledgedOffset,
            isOffsetHonored: isOffsetHonored,
            limit: limit,
            totalCount: totalCount,
            // 总数明确且已取满 → 到底了;总数没给才退回「不满页即到底」
            hasMore: Self.hasMore(
                fetched: entries.count,
                offset: acknowledgedOffset,
                limit: limit,
                totalCount: totalCount)
        )
    }

    /// 一次列完整个目录(自动翻页)。⛔ 只给「必须拿到全部内容」的场景用
    /// (如取直链前的 `pick_code` 补齐),浏览页走 `listPage` 按需翻。
    func list(cid: String, credential: Pan115Credential) async throws -> [Pan115FileEntry] {
        var entries: [Pan115FileEntry] = []
        var offset = 0
        for _ in 0..<Self.maxPages {
            let page = try await listPage(
                cid: cid, credential: credential, offset: offset, limit: Self.pageSize)
            entries.append(contentsOf: page.entries)
            guard page.hasMore else { break }
            // 服务端不认我们请求的 offset(它悄悄从头开始算了)→ 停,
            // ⛔ 不继续累加(否则同一个页面会被反复取,直到 maxPages)
            guard page.isOffsetHonored else { break }
            // 用服务端回显的 offset 推进,⛔ 不自行累加(防回绕)
            offset = page.nextOffset
        }
        return entries
    }

    /// 「还有没有下一页」的判据。
    ///
    /// - `totalCount` 给了就用它(准):目录总数减**已推进的条数**,还有剩就是还有下一页。
    ///   ⚠️ **不能**先看「本页满不满」:115 的 `limit` 可以远大于目录实际条目数
    ///   (目录只有 2 条而 `limit=1000`),不满页 ≠ 到底,总数说了算。
    /// - `totalCount` 没给才退回「本页不满 = 到底」(与 OpenList 一致)。
    ///
    /// ⚠️ 推进量用**服务端口径**(`offset + limit`),⛔ 不用 `fetched`:
    /// `fetched` 是解码**之后**的条数(缺 `cid` 的条目被丢掉),它少于服务端实际推进的条数
    /// ⇒ 用它算会误判「还有下一页」,多发一次空请求(115 按次记账,§6)。
    /// 两处口径必须一致:`nextOffset` 也是 `offset + limit`。
    static func hasMore(
        fetched: Int,
        offset: Int,
        limit: Int,
        totalCount: Int?
    ) -> Bool {
        if let totalCount {
            return offset + limit < totalCount
        }
        return fetched >= limit
    }

    func directoryID(path: String, credential: Pan115Credential) async throws -> String {
        let endpoint = Pan115Endpoint.directoryID(path: path)
        let data = try await send(endpoint, credential: credential).data
        let response: Pan115DirectoryIDResponse = try decode(data, endpoint: endpoint)
        guard let id = response.directoryID, !id.isEmpty else {
            throw Pan115Error.decoding(endpoint: endpoint.name, detail: "响应里没有 cid")
        }
        return id
    }

    // MARK: - 取直链(§4.1)

    /// 取一条文件的播放地址。
    ///
    /// 加密:请求体 `{"pickcode": …}` 用一次性的 16 字节 key 加密,响应 `data` 再用**同一个 key** 解开(§5)。
    /// 所以这个函数不能拆成两次调用 —— key 只在这一次请求里有效。
    func downloadURL(pickCode: String, credential: Pan115Credential) async throws
        -> Pan115DownloadLink
    {
        guard !pickCode.isEmpty else { throw Pan115Error.pickCodeMissing("pick_code 为空") }

        let key = Pan115Crypto.generateKey()
        let payload = try JSONEncoder().encode(["pickcode": pickCode])
        let encrypted = try Pan115Crypto.encode(payload, key: key)

        let endpoint = Pan115Endpoint.downloadURL(
            timestamp: Int(Date().timeIntervalSince1970), encryptedPayload: encrypted)
        let result = try await send(endpoint, credential: credential)
        let response: Pan115DownloadURLResponse = try decode(result.data, endpoint: endpoint)

        guard let cipher = response.data, !cipher.isEmpty else {
            throw Pan115Error.decoding(endpoint: endpoint.name, detail: "响应里没有 data")
        }
        let plaintext: Data
        do {
            plaintext = try Pan115Crypto.decode(cipher, key: key)
        } catch {
            throw Pan115Error.crypto("解开 downurl 响应失败:\(error)")
        }

        // `{fileID: {file_name, …, url: {url: …}}}` —— 只有一个 pickcode,取唯一那项
        let infos: [String: Pan115DownloadInfo]
        do {
            infos = try JSONDecoder().decode([String: Pan115DownloadInfo].self, from: plaintext)
        } catch {
            throw Pan115Error.decoding(
                endpoint: endpoint.name, detail: "解开后不是预期的 JSON(\(error))")
        }
        guard let info = infos.values.first, let url = info.url else {
            throw Pan115Error.pickCodeMissing(pickCode)
        }

        // 直链的 `f` 参数决定要带什么头(§4.3):空 = 什么都不要,1 = UA,3 = UA + Cookie
        return Pan115DownloadLink(
            url: url,
            headers: Self.playbackHeaders(
                for: url,
                cookie: credential.cookieHeader,
                responseCookies: result.setCookieHeaders
            )
        )
    }

    // MARK: - 传输

    /// 带响应的结果。取直链要读 `Set-Cookie`(`f=3` 的 Cookie 来源,§4.3),所以不能只返回 `Data`。
    struct Response: Sendable {
        let data: Data
        let setCookieHeaders: [String]
    }

    func send(_ endpoint: Pan115Endpoint, credential: Pan115Credential? = nil) async throws
        -> Response
    {
        try await limiter.acquire()
        guard let url = endpoint.url else {
            throw Pan115Error.transport("接口地址构造失败(\(endpoint.name))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        for (name, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let credential {
            request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let contentType = endpoint.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = endpoint.httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Pan115Error.transport("响应不是 HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                // 115 的风控会回 405 HTML(阿里云 WAF),状态码本身就是全部信息。
                // 403/405/429 一律当频控:进冷却,别等 WAF 把整个域名记上(§6)。
                if Self.rateLimitStatusCodes.contains(http.statusCode) {
                    await limiter.noteRateLimited()
                    throw Pan115Error.rateLimited(
                        retryAfter: await limiter.remainingCoolDown ?? 0)
                }
                throw Pan115Error.transport("HTTP \(http.statusCode)")
            }
            try await validate(data, endpoint: endpoint)
            return Response(data: data, setCookieHeaders: http.value(forHTTPHeaderField: "Set-Cookie")
                .map { [$0] } ?? [])
        } catch let error as Pan115Error {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // ⛔ 不用 `String(describing: error)`:`URLError` 的 userInfo 带完整 URL
            let nsError = error as NSError
            throw Pan115Error.transport(
                SecretRedactor.redacted(
                    "\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)"))
        }
    }

    /// 解码失败⛔ 不带响应体(可能有 Cookie 与直链签名)。
    func decode<T: Decodable & Sendable>(_ data: Data, endpoint: Pan115Endpoint) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Pan115Error.decoding(
                endpoint: endpoint.name, detail: Self.describe(error, data: data))
        }
    }

    /// 115 的风控状态码。`405` 是阿里云 WAF 的 HTML 拦截页;`403`/`429` 是同一回事的不同写法。
    /// 出处:§6 实测(`webapi.115.com/files` 无 Cookie 时回 405 HTML)。
    static let rateLimitStatusCodes: Set<Int> = [403, 405, 429]

    /// `state == 0` 就是业务失败。扫码接口的 `state` 语义不同(见各自响应类型),不走这里。
    private func validate(_ data: Data, endpoint: Pan115Endpoint) async throws {
        guard let envelope = try? JSONDecoder().decode(Pan115Envelope.self, from: data) else {
            return
        }
        guard let state = envelope.state, state == 0 else { return }
        let code = envelope.errorCode ?? 0
        // 频控排在错误码分派最前面:它是「现在别问了」,不是「这个请求有问题」
        if Pan115Code.tooFrequent.contains(code) {
            await limiter.noteRateLimited()
            throw Pan115Error.rateLimited(retryAfter: await limiter.remainingCoolDown ?? 0)
        }
        if code == Pan115Code.kickedOut { throw Pan115Error.kickedOut }
        if code == Pan115Code.notLoggedIn { throw Pan115Error.notAuthorized }
        // 二维码过期有两种表现:轮询响应里 `status: -1`,或 `state: 0` + 这个错误码。
        // 后一种在 `send` 阶段就被这里拦下,⛔ 不折成通用 server 错误 —— 否则用户看到的是
        // 「115 返回 40199002」而不是「二维码过期,请重新获取」。
        if code == Pan115Code.qrCodeExpired { throw Pan115Error.qrCodeExpired }
        throw Pan115Error.server(code: code, message: envelope.errorMessage)
    }

    // MARK: - 直链请求头

    /// 读直链 URL 上的 `f` 参数决定要带什么头(§4.3)。
    ///
    /// - `f` 空:什么都不要求
    /// - `f=1`:要 UA,且必须与取链时一致
    /// - `f=3`:要 UA + Cookie
    ///
    /// ⛔ 保守做法:即使 `f` 解析不出来也带上 UA —— 多带一个 UA 不会导致 403,少带会。
    static func playbackHeaders(
        for url: URL,
        cookie: String,
        responseCookies: [String]
    ) -> [String: String] {
        var headers = ["User-Agent": Pan115UserAgent.value]
        let requirement = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "f" }?
            .value ?? ""

        switch requirement {
        case "", "1":
            break
        case "3":
            // 优先用取链响应给的 `Set-Cookie`(115 校验的是这一份),没有再退回登录 Cookie
            if let issued = cookieValue(fromSetCookieHeaders: responseCookies) {
                headers["Cookie"] = issued
            } else {
                headers["Cookie"] = cookie
            }
        default:
            // 认不出的档位:带 UA 即可,⛔ 不猜
            break
        }
        return headers
    }

    /// 从 `Set-Cookie` 头里拼出 `name=value; name=value` 形式。
    ///
    /// 只取真正的 Cookie,**跳过属性**(`Path` / `Domain` / `Expires` / `Max-Age` / `HttpOnly` /
    /// `Secure` / `SameSite`)—— 它们是描述而不是键值对,混进 `Cookie` 请求头会被服务端当垃圾。
    static func cookieValue(fromSetCookieHeaders headers: [String]) -> String? {
        var pairs: [String] = []
        for header in headers {
            // 一个 Set-Cookie 头可能被合并成多段(以逗号分隔),取每段的第一项 `name=value`
            for part in header.split(separator: ",") {
                let first = part.split(separator: ";").first.map(String.init) ?? ""
                let trimmed = first.trimmingCharacters(in: .whitespaces)
                guard let separator = trimmed.firstIndex(of: "=") else { continue }
                let name = trimmed[trimmed.startIndex..<separator]
                let value = trimmed[trimmed.index(after: separator)...]
                guard !name.isEmpty, !value.isEmpty else { continue }
                guard !cookieAttributes.contains(name.lowercased()) else { continue }
                pairs.append("\(name)=\(value)")
            }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// `Set-Cookie` 里的属性名(小写),⛔ 不要当成 Cookie 发回去。
    private static let cookieAttributes: Set<String> = [
        "path", "domain", "expires", "max-age", "httponly", "secure", "samesite", "priority",
    ]

    // MARK: - 工具

    static func milliseconds(now: Date = Date()) -> Int {
        Int(now.timeIntervalSince1970 * 1000)
    }

    /// `DecodingError` 的可读描述,点名到字段。⛔ 只带键名不带值。
    private static func describe(_ error: any Error, data: Data) -> String {
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

/// 一条可播放的直链 + 它要求的请求头。
struct Pan115DownloadLink: Sendable, Equatable {
    let url: URL
    let headers: [String: String]
}

/// 串行限速器 + 频控冷却(`docs/PAN115_API.md` §6 的硬约束:两次请求间隔 ≥ 500ms)。
///
/// 115 对第三方客户端的频控是**硬性**的:超了先回 `590075 操作太频繁`,再超就是阿里云 WAF 拦截。
/// ⛔ 不要并发打 115;⛔ 不要把间隔调到 500ms 以下。
///
/// 命中一次频控后进入冷却:冷却期内 `acquire()` 直接抛 `rateLimited`,**一个请求都不发**。
/// 为什么必须这样:WAF 的拦截按域名记账(§6),被拦之后还继续请求只会把冷却时间越拖越长。
actor Pan115RateLimiter {
    init(minimumInterval: Duration = .milliseconds(500)) {
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
                throw Pan115Error.rateLimited(
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
    func noteRateLimited(for duration: Duration = Pan115Policy.rateLimitCoolDown) {
        let until = ContinuousClock.now.advanced(by: duration)
        if let current = coolDownUntil, current > until { return }
        coolDownUntil = until
        // 冷却结束后第一发也要满足最小间隔,不趁刚恢复就连打
        lastRequest = nil
    }

    /// 当前冷却剩余秒数,`nil` = 不在冷却中。UI 用来决定按钮要不要禁用。
    var remainingCoolDown: TimeInterval? {
        guard let until = coolDownUntil else { return nil }
        let remaining = ContinuousClock.now.duration(to: until)
        return remaining > .zero ? TimeInterval(remaining.components.seconds) : nil
    }
}
