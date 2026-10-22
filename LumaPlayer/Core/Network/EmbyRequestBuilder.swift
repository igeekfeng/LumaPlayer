import Foundation

/// Emby 请求的唯一构造处:URL、认证头、token 头、请求体(API_CONTRACT.md 1.2、2.1、2.2)。
/// ⛔ View / ViewModel 不得自己拼 URL 或读 token。
struct EmbyRequestBuilder: Sendable, Equatable {
    /// `Authorization` 头里的 Client(API_CONTRACT.md 2.1)
    static let clientName = "LumaPlayer"
    /// 秒。探测阶段要连两次,不宜太长。
    static let timeoutInterval: TimeInterval = 20

    /// 站点根,**不含** `/emby`(API_CONTRACT.md 1.2)
    var baseURL: URL
    /// `/emby` 或 ""。探测确定后写入,不得每次重猜(1.2、1.4)
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
        // 本机名含非 ASCII 时清洗为空 → 回退 Mac(API_CONTRACT.md 2.1);不做转写,结果不可预期
        let rawDevice = deviceName ?? Host.current().localizedName ?? "Mac"
        let cleaned = Self.sanitizedHeaderComponent(rawDevice)
        self.deviceName = cleaned.isEmpty ? "Mac" : cleaned
        // 不要硬编码版本号(2.1)
        self.appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    init(profile: ServerProfile, deviceName: String? = nil, appVersion: String? = nil) {
        self.init(
            baseURL: profile.baseURL,
            apiPathPrefix: profile.apiPathPrefix,
            deviceID: profile.deviceID,
            deviceName: deviceName,
            appVersion: appVersion
        )
    }

    /// 请求体编码失败时抛出。
    func makeRequest(for endpoint: EmbyEndpoint, accessToken: String?, userID: String?) throws -> URLRequest {
        guard let url = url(for: endpoint) else {
            // 本地拼接出错;不猜一个「差不多」的 URL 继续发
            throw EmbyAPIError.transport(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = Self.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 自定义 UA 逐请求读取;没填就沿用系统默认
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

    /// PlaybackInfo / 播放上报走 `JSONEncoder`:要真正的 JSON 布尔与整数,字符串表会写成 `"false"`。
    private func encodedBody(_ body: EmbyEndpoint.EmbyRequestBody) throws -> Data {
        switch body {
        case .fields(let fields):
            return try JSONSerialization.data(withJSONObject: fields)
        case .playbackInfo(let request):
            return try JSONEncoder().encode(request)
        case .playbackReport(let body):
            return try JSONEncoder().encode(body)
        }
    }

    /// baseURL + `/emby` 前缀 + 端点路径 + 查询串(值的编码交给 `URLComponents`)。
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

    /// `Emby UserId="...", Client="...", Device="...", DeviceId="...", Version="..."`(API_CONTRACT.md 2.1)。
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

    /// 去掉双引号与反斜杠;含非 ASCII 时返回空串,由调用方决定回退
    /// (直接塞进 `URLRequest.setValue` 行为不可靠,API_CONTRACT.md 2.1)。
    static func sanitizedHeaderComponent(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        guard stripped.allSatisfy({ $0.isASCII }) else { return "" }
        return stripped
    }

    /// 清洗后为空返回 nil,整段省略。
    private static func quotedField(_ key: String, _ value: String) -> String? {
        let cleaned = sanitizedHeaderComponent(value)
        guard !cleaned.isEmpty else { return nil }
        return "\(key)=\"\(cleaned)\""
    }
}
