import Foundation

/// Emby 请求的唯一构造处:URL 拼接、认证头、token 头、请求体
/// (ARCHITECTURE.md 6.3;API_CONTRACT.md 1.2、2.1、2.2)。
///
/// 值类型、无状态 → 天然 Sendable,可以不经过 actor 直接单测。
/// ⛔ View / ViewModel 不得自己拼 URL 或读 token —— 一律经由本类型。
struct EmbyRequestBuilder: Sendable, Equatable {
    /// `Authorization` 头里的 Client 固定值(API_CONTRACT.md 2.1)
    static let clientName = "LumaPlayer"
    /// 单请求超时(秒)。探测阶段要连两次,不宜太长。
    static let timeoutInterval: TimeInterval = 20

    /// 站点根,**不含** `/emby`(API_CONTRACT.md 1.2)
    var baseURL: URL
    /// `/emby` 或 ""。由探测确定后写入,不得每次请求重猜(1.2、1.4)
    var apiPathPrefix: String
    var deviceID: String
    var deviceName: String
    var appVersion: String

    init(
        baseURL: URL,
        apiPathPrefix: String = "",
        deviceID: String,
        deviceName: String? = nil,
        appVersion: String? = nil
    ) {
        self.baseURL = baseURL
        self.apiPathPrefix = apiPathPrefix
        self.deviceID = deviceID
        // 本机名可能含非 ASCII(中文机器名):清洗后为空则回退 Mac
        // (API_CONTRACT.md 2.1)。不做转写 —— 转写结果不可预期,回退更安全。
        let rawDevice = deviceName ?? Host.current().localizedName ?? "Mac"
        let cleaned = Self.sanitizedHeaderComponent(rawDevice)
        self.deviceName = cleaned.isEmpty ? "Mac" : cleaned
        // CFBundleShortVersionString,不要硬编码(2.1);取不到时留占位串
        self.appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    /// 由服务器档案构造(常用入口)。
    init(profile: ServerProfile, deviceName: String? = nil, appVersion: String? = nil) {
        self.init(
            baseURL: profile.baseURL,
            apiPathPrefix: profile.apiPathPrefix,
            deviceID: profile.deviceID,
            deviceName: deviceName,
            appVersion: appVersion
        )
    }

    /// 构造 URLRequest。请求体编码失败(JSON 序列化)时抛出。
    func makeRequest(for endpoint: EmbyEndpoint, accessToken: String?, userID: String?) throws -> URLRequest {
        guard let url = url(for: endpoint) else {
            // 构造不出来就是本地拼接出错;不猜一个「差不多」的 URL 继续发
            throw EmbyAPIError.transport(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = Self.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 用户自定义 UA(设置 → 网络)逐请求读取;没填就不设,沿用系统默认(以 LumaPlayer/版本 开头)
        if let userAgent = ClientUserAgent.custom {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue(authorizationHeaderValue(userID: userID), forHTTPHeaderField: "Authorization")
        if let token = accessToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        if let body = endpoint.body {
            request.httpBody = try encodedBody(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// 请求体编码。登录是扁平字符串表;播放上报走 `JSONEncoder` ——
    /// 它们需要真正的 JSON 布尔值与整数,用字符串表会把 `false` 写成 `"false"`。
    ///
    /// PlaybackInfo 也走 `JSONSerialization`,原因是它要**原样嵌入** Rust 派生出来的
    /// 整份 `DeviceProfile`(见 `PlaybackInfoRequest.bodyData()`)。
    private func encodedBody(_ body: EmbyEndpoint.EmbyRequestBody) throws -> Data {
        switch body {
        case .fields(let fields):
            return try JSONSerialization.data(withJSONObject: fields)
        case .playbackInfo(let request):
            return try request.bodyData()
        case .playbackReport(let body):
            return try JSONEncoder().encode(body)
        }
    }

    /// 完整 URL:baseURL + `/emby` 前缀 + 端点路径 + 查询串。
    /// 查询串由 `URLComponents` 生成,值里的特殊字符交给系统编码。
    func url(for endpoint: EmbyEndpoint) -> URL? {
        var url = baseURL
        if !apiPathPrefix.isEmpty {
            url.append(path: apiPathPrefix)
        }
        url.append(path: endpoint.path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if !endpoint.queryItems.isEmpty {
            components.queryItems = endpoint.queryItems.map {
                URLQueryItem(name: $0.name, value: $0.value)
            }
        }
        return components.url
    }

    /// `Authorization` 头的完整值(API_CONTRACT.md 2.1)。
    ///
    /// 格式:`Emby UserId="...", Client="...", Device="...", DeviceId="...", Version="..."`
    /// 未登录时**省略整段 UserId**,不要写成空字符串。
    func authorizationHeaderValue(userID: String?) -> String {
        let fields: [String?] = [
            userID.flatMap { Self.quotedField("UserId", $0) },
            Self.quotedField("Client", Self.clientName),
            Self.quotedField("Device", deviceName),
            Self.quotedField("DeviceId", deviceID),
            Self.quotedField("Version", appVersion),
        ]
        return "Emby " + fields.compactMap { $0 }.joined(separator: ", ")
    }

    /// header 值的清洗(API_CONTRACT.md 2.1):
    /// 去掉会破坏 header 语法的双引号与反斜杠;含非 ASCII 时返回空串
    /// (由调用方决定是否回退 —— 直接塞进 `URLRequest.setValue` 行为不可靠)。
    static func sanitizedHeaderComponent(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        guard stripped.allSatisfy({ $0.isASCII }) else { return "" }
        return stripped
    }

    /// 组装 `Key="value"`;值为空(被清洗掉)时返回 nil,整段省略。
    private static func quotedField(_ key: String, _ value: String) -> String? {
        let cleaned = sanitizedHeaderComponent(value)
        guard !cleaned.isEmpty else { return nil }
        return "\(key)=\"\(cleaned)\""
    }
}
