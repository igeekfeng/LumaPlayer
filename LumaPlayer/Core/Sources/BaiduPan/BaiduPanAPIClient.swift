import Foundation

/// 百度网盘的 HTTP 客户端(纯传输 + 解码,⛔ 不含授权状态机、不碰凭据;刷新 / 重新授权在 `BaiduPanConnection`)。
///
/// 业务错误码在 HTTP 200 的响应体里(`errno`,0 才算成功),⛔ 不能只看状态码。
/// 失败抛 `BaiduPanError.server`,由上层处置(`docs/BAIDU_PAN_API.md` §4 - §5)。
struct BaiduPanAPIClient: Sendable {

    /// 独立会话、关掉缓存与 cookie:`access_token` 在 URL 上,⛔ 不能让带凭据的 URL 落盘;
    /// 列表与元信息也要求刚改过就能看到。
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

    /// `list()` 自动翻页时的一页条数。官方建议上限 1000(`docs/BAIDU_PAN_API.md` §7.1),⛔ 别调大。
    /// ⚠️ 只服务「必须一次拿整层」的 `list()`:配额按次记,一次多拿能少发几次请求。
    /// 浏览页走 `listPage(...,limit:)`,条数由 `FileSourceViewModel.browsePageSize` 给,⛔ 不用这个值。
    static let pageSize = 1000
    /// `list()` 最多翻几页。⛔ 这是**本项目自定的预算**(配额极低,§7),不是接口上限;
    /// 到上限就停,`list()` 返回的可能是目录的前面一截。
    static let maxPages = 5

    // MARK: - 授权

    func deviceCode(clientID: String) async throws -> BaiduPanDeviceCode {
        let endpoint = BaiduPanEndpoint.deviceCode(
            clientID: clientID, scope: BaiduPanAppCredentials.scope)
        let data = try await send(endpoint)
        let response: BaiduPanDeviceCodeResponse = try decode(data, endpoint: endpoint)
        return response.deviceCodeValue
    }

    /// 用设备码换 token,轮询时调用。
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

    /// ⚠️ 调用方必须保证单飞(`refresh_token` 只能用一次,§6)。
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

    /// 列一页。`start` 是偏移量(`start += limit` 翻页,官方推荐的分页方式)。
    ///
    /// ⛔ **单页**返回,不做自动翻页:浏览页要按需取(滚到底再取下一页),
    /// 一次把整个目录拉完在配额下不划算(`docs/BAIDU_PAN_API.md` §7)。
    ///
    /// `method=list` 的响应**没有**总数字段(既无 `total` 也无 `has_more` —— 那两个是
    /// `method=listall` 的字段,见 §2.2),所以「还有没有下一页」只能靠
    /// 「这一页不满」推断(与 OpenList 的做法一致)。
    func listPage(
        directory: String,
        accessToken: String,
        start: Int,
        limit: Int
    ) async throws -> BaiduPanDirectoryPage {
        let endpoint = BaiduPanEndpoint.fileList(
            accessToken: accessToken,
            directory: directory,
            start: start,
            limit: limit
        )
        let data = try await send(endpoint)
        let response: BaiduPanListResponse = try decode(data, endpoint: endpoint)
        let rawEntries = response.list ?? []
        let entries = rawEntries.compactMap(\.file)
        // ⚠️ 判据用**原始条数**(`rawEntries`),⛔ 不用 `entries.count`:
        // 解码时丢掉缺 `path` / `fs_id` 的条目会让 `entries.count` 少于服务端实际返回的条数,
        // 用它判「满不满」会误判成到底。
        let fetched = rawEntries.count
        return BaiduPanDirectoryPage(
            files: entries,
            // 不满一页 = 到底了(`has_more` 是 `listall` 的字段,`list` 没有)
            hasMore: fetched >= limit,
            // 官方推荐的翻页方式是 `start + limit`,⛔ 不能用 `files.count`(会漏项)
            nextOffset: start + limit
        )
    }

    /// 一次列完整个目录(自动翻页)。⛔ 只给「必须拿到全部内容」的场景用
    /// (如取直链前的 `pick_code` 补齐),浏览页走 `listPage` 按需翻。
    func list(directory: String, accessToken: String) async throws -> [BaiduPanFile] {
        var files: [BaiduPanFile] = []
        var start = 0
        for _ in 0..<Self.maxPages {
            let result = try await listPage(
                directory: directory, accessToken: accessToken,
                start: start, limit: Self.pageSize)
            files.append(contentsOf: result.files)
            guard result.hasMore else { break }
            // 用服务端口径的下一页起点(=`start + limit`),⛔ 不自行累加
            start = result.nextOffset
        }
        return files
    }

    /// 单条元信息(含 `dlink`,8 小时有效)。接口选择见 `BaiduPanEndpoint.fileMeta`。
    func meta(fsID: UInt64, accessToken: String) async throws -> BaiduPanFileMeta {
        let entries = try await metas(fsIDs: [fsID], accessToken: accessToken)
        // `errno != 0` 已被 `validate` 拦下,这里空列表 = 该 fs_id 没有对应文件
        guard let entry = entries.first else {
            throw BaiduPanError.server(errno: BaiduPanErrno.notFound, message: nil)
        }
        return entry
    }

    /// 批量取元信息(含 `dlink`)。批量是配额要求(§7),逐条取会瞬间烧光。
    /// 返回顺序不保证与传入一致,调用方按 `fs_id` 配对。
    func metas(fsIDs: [UInt64], accessToken: String) async throws -> [BaiduPanFileMeta] {
        guard !fsIDs.isEmpty else { return [] }
        let endpoint = BaiduPanEndpoint.fileMeta(accessToken: accessToken, fsIDs: fsIDs)
        let data = try await send(endpoint)
        let response: BaiduPanMetaResponse = try decode(data, endpoint: endpoint)
        return response.list ?? []
    }

    // MARK: - 删除

    /// 删一条文件或目录(`docs/BAIDU_PAN_API.md` §2.4)。
    ///
    /// ⛔ 顶层 `errno == 0` 只表示受理,单条结果在 `info[].errno`(常见 `-9` 已不存在),只看顶层会把没删掉吞成成功。
    func delete(path: String, accessToken: String) async throws {
        let endpoint = BaiduPanEndpoint.deleteFile(accessToken: accessToken, path: path)
        let data = try await send(endpoint)
        let response: BaiduPanFileManagerResponse = try decode(data, endpoint: endpoint)
        // `async=0` 必须给逐条结果;没给(异步只回 `taskid`)就说不清删没删成
        guard let info = response.info, !info.isEmpty else {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name, detail: "响应里没有逐条删除结果")
        }
        // 多于一条时按 path 认领,认不出⛔ 不猜,直接当失败
        guard let entry = info.count == 1 ? info[0] : info.first(where: { $0.path == path }) else {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name, detail: "删除结果里没有这条路径")
        }
        guard entry.errno == 0 else {
            throw BaiduPanError.server(errno: entry.errno, message: nil)
        }
    }

    // MARK: - 改名

    /// 批量改名(`docs/BAIDU_PAN_API.md` §2.5)。
    ///
    /// - Returns: 逐条结果,按请求顺序与 `operations` 一一对应。
    ///
    /// ⚠️ 顺序对应是未实测的假设(§2.7 第 3 条),所以条数与提交不等就整批失败,⛔ 不猜对应关系。
    func rename(
        _ operations: [BaiduPanRenameOperation],
        accessToken: String
    ) async throws -> [BaiduPanFileManagerResponse.Info] {
        guard !operations.isEmpty else { return [] }
        let endpoint = BaiduPanEndpoint.renameFiles(
            accessToken: accessToken, operations: operations)
        let data = try await send(endpoint)
        let response: BaiduPanFileManagerResponse = try decode(data, endpoint: endpoint)
        guard let info = response.info else {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name, detail: "响应里没有逐条改名结果")
        }
        guard info.count == operations.count else {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name,
                detail: "逐条结果 \(info.count) 条,与提交的 \(operations.count) 条对不上")
        }
        return info
    }

    // MARK: - 播放流探测

    /// 起播前探一次 `method=streaming`(只要状态)。
    ///
    /// - Returns: `nil` 表示可以播;非 nil 是要展示给用户的失败。
    ///   `133`(非会员要看广告)先带 `adToken` 重试一次(§5),仍失败才算失败。
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

    /// 传输层校验在这里,业务错误码交给 `validate`。
    func send(_ endpoint: BaiduPanEndpoint) async throws -> Data {
        guard let url = endpoint.url else {
            throw BaiduPanError.configuration("接口地址构造失败(\(endpoint.name))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        for (name, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // 只有 `method=filemanager` 带 form body
        if let contentType = endpoint.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = endpoint.httpBody
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
            // ⛔ 不用 `String(describing: error)`:`URLError` 的 userInfo 带完整 URL(含 `access_token`)
            let nsError = error as NSError
            throw BaiduPanError.transport(
                SecretRedactor.redacted("\(nsError.domain) \(nsError.code):\(nsError.localizedDescription)"))
        }
    }

    /// 解码失败⛔ 不带响应体(可能有 token)。
    func decode<T: Decodable & Sendable>(_ data: Data, endpoint: BaiduPanEndpoint) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BaiduPanError.decoding(
                endpoint: endpoint.name, detail: Self.describe(error, data: data))
        }
    }

    /// 先判 `errno`(网盘接口总带,成功为 0),再判 OAuth 的 `error`(OAuth 响应没有 `errno`)。
    private func validate(_ data: Data, endpoint: BaiduPanEndpoint) throws {
        if let envelope = try? JSONDecoder().decode(BaiduPanErrnoEnvelope.self, from: data),
           let errno = envelope.errno, errno != 0 {
            throw BaiduPanError.server(errno: errno, message: envelope.showMessage)
        }
        if let oauth = try? JSONDecoder().decode(BaiduPanOAuthErrorResponse.self, from: data) {
            // ⛔ 不折成 `notAuthorized`:设备码轮询的「用户还没确认」也是 OAuth 错误,上层要看具体码
            // (`BaiduPanError.isFatalOAuthCode`)
            throw BaiduPanError.oauth(code: oauth.error, message: oauth.errorDescription)
        }
    }

    /// `DecodingError` 的可读描述,点名到字段,并附响应顶层键名以便定位响应形状变化。
    /// ⛔ 只带键名不带值(值里可能有 token / dlink 签名)。
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

    /// 最多 12 个,只进错误文案。不是 JSON 对象时返回 nil。
    static func topLevelKeys(in data: Data) -> [String]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        return object.keys.sorted().prefix(12).map { $0 }
    }
}
