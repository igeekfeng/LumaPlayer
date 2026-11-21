import Foundation

/// PanSou 实例的适配器。
///
/// 协议取自 PanSou 源码(`api/handler.go` + `model/response.go`,见会话分析):
/// `POST {base}/api/search`,请求体 `{kw, res, src, cloud_types}`,响应
/// `{code, message, data: {total, results[], merged_by_type}}`。
///
/// 为什么用 `res=results` 而不是默认的 `merge`:默认档只回 `merged_by_type`,
/// 那里每条链接**没有标题**(只有 `note` / `source`),而本模块的列表按标题展示、
/// 按标题和用户搜索意图对齐。多花一点带宽换可读的标题是值得的。
///
/// ⚠️ 不传 `channels`:那一路是「拼 `t.me/s/<频道>?q=` 抓 HTML」,依赖 Telegram 可达性,
/// 在本机网络环境下经常整段失败。要它就在源配置里换一个 `src` 值(见 `srcMode`)。
struct PanSouAdapter: ResourceSourceAdapter {
    let kind: ResourceSourceAdapterKind = .panSou

    /// `all` = TG 频道 + 插件;`plugin` = 只跑插件。
    ///
    /// 默认只跑插件:TG 路径要 `t.me` 可达,而插件路径打的是各站点自己的搜索接口,
    /// 在本项目这种「用户本机直连」的场景下成功率明显更高。⛔ 不把它做成隐藏开关 ——
    /// 失败信息里会写清这次跑的是哪一路。
    let srcMode: String

    private let session: URLSession

    init(session: URLSession, srcMode: String = "plugin") {
        self.session = session
        self.srcMode = srcMode
    }

    func search(keyword: String, source: ResourceSource) async throws -> [PanResource] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PanResourceSearchError.emptyKeyword }
        guard let url = Self.searchURL(baseURL: source.baseURL) else {
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id, statusCode: nil, message: "源地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "kw": trimmed,
            // 只取 results:标题在 results 里,merged_by_type 里没有
            "res": "results",
            "src": srcMode,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            guard error.code != .cancelled else { throw CancellationError() }
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id, statusCode: nil, message: URLErrorDescription.userText(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id, statusCode: nil, message: "响应不是 HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id,
                statusCode: http.statusCode,
                message: Self.envelopeMessage(data))
        }

        let decoded: PanSouSearchEnvelope
        do {
            decoded = try JSONDecoder().decode(PanSouSearchEnvelope.self, from: data)
        } catch {
            // 反爬页 / 登录页也会是 200,这里必须把「不是 JSON」说清楚,⛔ 不能当成「没搜到」
            throw PanResourceSearchError.decoding(
                sourceID: source.id, detail: Self.decodeDetail(error))
        }
        guard decoded.code == 0 else {
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id,
                statusCode: http.statusCode,
                message: decoded.message ?? "业务错误码 \(decoded.code)")
        }
        return (decoded.data?.results ?? []).compactMap { entry in
            Self.resource(from: entry, source: source)
        }
    }

    // MARK: - 形状

    static let timeout: TimeInterval = 20

    /// `{base}/api/search`。base 带不带尾斜杠、带不带子路径都能拼对。
    static func searchURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/api/search")
    }

    private static func resource(from entry: PanSouSearchResult, source: ResourceSource) -> PanResource? {
        let links = entry.links.compactMap { link -> PanResourceLink? in
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            return PanResourceLink(
                url: url,
                cloudType: PanCloudType(rawValue: link.type.lowercased()) ?? .unknown,
                // PanSou 用空串表示「不要码」,模型层统一成 nil
                password: link.password.flatMap { $0.isEmpty ? nil : $0 })
        }
        // ⛔ 没有链接的条目不是资源(纯文本消息),不进列表
        guard !links.isEmpty else { return nil }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return PanResource(
            // unique_id 是 PanSou 的全局唯一 id;缺失时退回 message_id
            id: entry.uniqueID ?? entry.messageID ?? UUID().uuidString,
            title: title.isEmpty ? "无标题资源" : title,
            summary: entry.content.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) },
            publishedAt: entry.datetime.flatMap(Self.parseDate),
            links: links,
            sourceID: source.id,
            rank: nil)
    }

    /// PanSou 的 `datetime` 是 Go 的 `time.Time`(RFC3339,带时区)。
    static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func envelopeMessage(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(PanSouSearchEnvelope.self, from: data) else {
            return nil
        }
        return envelope.message
    }

    private static func decodeDetail(_ error: any Error) -> String {
        switch error {
        case let decoding as DecodingError:
            switch decoding {
            case .keyNotFound(let key, _): return "缺少字段 \(key.stringValue)"
            case .typeMismatch(_, let context):
                return "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 类型不对"
            case .valueNotFound(_, let context):
                return "字段 \(context.codingPath.map(\.stringValue).joined(separator: ".")) 为 null"
            case .dataCorrupted: return "不是合法 JSON(可能是反爬页或登录页)"
            @unknown default: return "无法解析"
            }
        default:
            return "无法解析"
        }
    }
}

// MARK: - 线格式

/// PanSou 的通用响应信封:`{code, message, data}`。`code == 0` 为成功。
struct PanSouSearchEnvelope: Decodable, Sendable {
    let code: Int
    let message: String?
    let data: PanSouSearchData?
}

struct PanSouSearchData: Decodable, Sendable {
    let total: Int?
    /// `res=results` / `res=all` 时才有
    let results: [PanSouSearchResult]?
}

/// 一条 PanSou 搜索结果。字段名取自 `model.SearchResult`。
struct PanSouSearchResult: Decodable, Sendable {
    let messageID: String?
    let uniqueID: String?
    let channel: String?
    let datetime: String?
    let title: String
    let content: String?
    let links: [PanSouLink]

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case uniqueID = "unique_id"
        case channel
        case datetime
        case title
        case content
        case links
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // title 在 PanSou 里必有,但第三方实例不一定 —— 缺了当空串,由上层给「无标题资源」
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        uniqueID = try container.decodeIfPresent(String.self, forKey: .uniqueID)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        datetime = try container.decodeIfPresent(String.self, forKey: .datetime)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        // links 缺失 = 这条没有资源(纯文本消息),不是解码失败
        links = try container.decodeIfPresent([PanSouLink].self, forKey: .links) ?? []
    }
}

/// `model.Link`。`type` 是网盘类型字符串(`baidu` / `quark` / `115` / `magnet`…)。
struct PanSouLink: Decodable, Sendable {
    let type: String
    let url: String
    let password: String?

    enum CodingKeys: String, CodingKey {
        case type
        case url
        case password
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password)
    }
}
