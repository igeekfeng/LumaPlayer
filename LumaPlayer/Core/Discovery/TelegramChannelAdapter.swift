import Foundation

/// Telegram **公开频道**的网页搜索适配器。
///
/// 端点:`GET https://t.me/s/{频道}?q={关键词}`,翻页再加 `&before={最小消息 id}`。
/// 这是 Telegram 给未登录用户看的公开预览页,不需要 token、不需要登录,
/// 页面上每条消息带着 `data-post="频道/消息id"`、`<time datetime>` 和正文。
///
/// 为什么不走 PanSou:那一档会把关键词扇到上百个源,噪声大且依赖别人维护的实例。
/// 这里一个源 = 一个频道,清单是用户自己的数据 —— 想要什么口味就只留那几个频道。
///
/// ⚠️ 频道不存在时 `t.me/s/...` 会 302 到 `t.me/<频道>`(联系页),`URLSession` 跟随后
/// 拿到的是一个没有消息块的页面。所以「解析出 0 条」必须和「频道名错了」分开报,
/// 否则用户会以为自己把关键词写错了。
struct TelegramChannelAdapter: ResourceSourceAdapter {
    let kind: ResourceSourceAdapterKind = .telegramChannel

    private let session: URLSession

    /// 最多翻几页。一页 20 条;限 2 页是「够用且不拖慢」的折中。
    static let maxPages = 2
    static let timeout: TimeInterval = 20

    init(session: URLSession) {
        self.session = session
    }

    func search(keyword: String, source: ResourceSource) async throws -> [PanResource] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PanResourceSearchError.emptyKeyword }
        guard let channel = Self.channelName(from: source.baseURL) else {
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id, statusCode: nil, message: "频道名无效:\(source.baseURL)")
        }

        var collected: [PanResource] = []
        var before: String?
        for _ in 0..<Self.maxPages {
            let page = try await fetchPage(
                channel: channel, keyword: trimmed, before: before, source: source)
            collected.append(contentsOf: page.resources)
            // 没有「更早」链接就到此为止,不再白打一次请求
            guard let next = page.olderThan, !page.resources.isEmpty else { break }
            before = next
        }
        return collected
    }

    // MARK: - 单页

    private struct Page {
        let resources: [PanResource]
        /// 下一页的 `before`(页面上「更早」链接带的 `data-before`)
        let olderThan: String?
    }

    private func fetchPage(
        channel: String,
        keyword: String,
        before: String?,
        source: ResourceSource
    ) async throws -> Page {
        guard let url = Self.searchURL(channel: channel, keyword: keyword, before: before) else {
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id, statusCode: nil, message: "搜索地址拼不出来")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        // 桌面 UA:移动端页面结构不同,统一按桌面预览页解析
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

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
                sourceID: source.id, statusCode: http.statusCode, message: nil)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PanResourceSearchError.decoding(
                sourceID: source.id, detail: "页面不是 UTF-8 文本")
        }
        // 302 跟随后落在频道联系页:频道名写错了,不是「没搜到」
        guard html.contains("tgme_widget_message") || html.contains("tgme_channel_info") else {
            throw PanResourceSearchError.sourceFailed(
                sourceID: source.id,
                statusCode: http.statusCode,
                message: "频道 @\(channel) 不存在或已关闭")
        }

        let resources = Self.parseMessages(html, channel: channel, source: source)
        return Page(resources: resources, olderThan: Self.parseOlderThan(html))
    }

    // MARK: - 解析

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 从用户填的内容里取频道名:接受 `@name` / `name` / `https://t.me/name` / `https://t.me/s/name`。
    ///
    /// ⛔ 不做「猜」:带路径的链接只认 `t.me` 域下第一段(或 `/s/` 之后那段),
    /// 其它形态一律当无效,让设置页直接说「频道名无效」。
    static func channelName(from raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("@") { trimmed.removeFirst() }

        if let url = URL(string: trimmed), let host = url.host()?.lowercased(),
           host == "t.me" || host == "telegram.me" {
            var parts = url.path().split(separator: "/").map(String.init)
            if parts.first == "s" { parts.removeFirst() }
            return parts.first.flatMap(validChannelName)
        }
        return validChannelName(trimmed)
    }

    /// Telegram 频道名:字母 / 数字 / 下划线,4–32 位(官方限制)。
    private static func validChannelName(_ raw: String) -> String? {
        guard (4...32).contains(raw.count) else { return nil }
        let allowed = raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return allowed ? raw : nil
    }

    /// `https://t.me/s/{channel}?q={keyword}[&before={id}]`
    static func searchURL(channel: String, keyword: String, before: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "t.me"
        components.path = "/s/\(channel)"
        var items = [URLQueryItem(name: "q", value: keyword)]
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        components.queryItems = items
        return components.url
    }

    /// 「更早的消息」链接:`<a ... data-before="104198">`
    static func parseOlderThan(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"data-before="(\d+)""#) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let capture = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[capture])
    }

    /// 把整页 HTML 切成每条消息,再逐条转成 `PanResource`。
    ///
    /// 切块用 `data-post="…"` 而不是嵌套的 `<div>`:消息正文里嵌着 `<a>` / `<i>` / `<mark>`,
    /// 按标签配对容易错位,而 `data-post` 每条消息只出现一次、顺序就是页面顺序。
    static func parseMessages(
        _ html: String,
        channel: String,
        source: ResourceSource
    ) -> [PanResource] {
        let markers = postMarkers(in: html)
        guard !markers.isEmpty else { return [] }
        var resources: [PanResource] = []
        for (index, marker) in markers.enumerated() {
            let start = marker.lowerBound
            let end = index + 1 < markers.count ? markers[index + 1].lowerBound : html.endIndex
            let block = String(html[start..<end])
            if let resource = resource(from: block, channel: channel, source: source) {
                resources.append(resource)
            }
        }
        return resources
    }

    /// 每条消息块在原文里的起点范围(按出现顺序)。
    private static func postMarkers(in html: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"data-post=""#) else { return [] }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: full).compactMap { match in
            Range(match.range, in: html)
        }
    }

    private static func resource(
        from block: String,
        channel: String,
        source: ResourceSource
    ) -> PanResource? {
        guard let postID = firstCapture(#"data-post="([^"]+)""#, in: block) else { return nil }
        guard let textHTML = firstCapture(
            #"<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>"#, in: block)
        else { return nil }

        let links = PanShareLinkExtractor.links(inHTML: textHTML)
        // ⛔ 没有网盘链接的消息不是资源(纯文字更新 / 只有标签),不进列表
        guard !links.isEmpty else { return nil }

        let plain = PanShareLinkExtractor.plainText(fromHTML: textHTML)
        return PanResource(
            id: postID,
            title: title(fromPlainText: plain, fallback: postID),
            summary: summary(fromPlainText: plain),
            publishedAt: firstCapture(#"<time[^>]*datetime="([^"]+)""#, in: block)
                .flatMap(Self.parseDate),
            links: links,
            sourceID: source.id,
            rank: nil)
    }

    /// 频道消息的正文多半是「名称:xxx / 描述:yyy / 百度:链接」这种固定格式。
    /// 有 `名称:` 就用它;没有就取第一行非空文本。
    static func title(fromPlainText text: String, fallback: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let named = lines.first(where: { $0.hasPrefix("名称") }) {
            let value = named
                .replacingOccurrences(of: "名称", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
            if !value.isEmpty { return String(value.prefix(120)) }
        }
        guard let first = lines.first else { return "无标题资源" }
        return String(first.prefix(120))
    }

    /// 摘要取「描述」那段;没有就取去掉首行后的前 200 字。
    static func summary(fromPlainText text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let described = lines.first(where: { $0.hasPrefix("描述") }) {
            let value = described
                .replacingOccurrences(of: "描述", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
            if !value.isEmpty { return String(value.prefix(400)) }
        }
        let rest = lines.dropFirst().joined(separator: " ")
        return rest.isEmpty ? nil : String(rest.prefix(400))
    }

    /// Telegram 的 `<time datetime>` 是 RFC3339(带时区)。
    static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }
}

/// 从一段消息 HTML / 纯文本里抽网盘分享链接。
///
/// 独立成类型是因为两个地方都要用:频道消息解析(HTML)与将来的其它文本源(纯文本)。
/// 只做**确定性**抽取:认域名 → 交给 `PanShareLink.parse`,⛔ 不猜网盘类型。
enum PanShareLinkExtractor {
    /// 从 HTML 片段抽链接:优先取 `<a href>`(Telegram 会把 URL 包成锚点),
    /// 再补上正文里裸写的 URL(有些频道用 `code` 块贴链接)。
    static func links(inHTML html: String) -> [PanResourceLink] {
        var candidates: [String] = []
        for href in captures(#"<a[^>]+href="((?:https?|magnet|ed2k):[^"]+)""#, in: html) {
            candidates.append(unescape(href))
        }
        let plain = plainText(fromHTML: html)
        candidates.append(contentsOf: urls(inPlainText: plain))
        return links(fromCandidates: candidates, passwordSource: plain)
    }

    /// 从纯文本抽链接。
    static func links(inPlainText text: String) -> [PanResourceLink] {
        links(fromCandidates: urls(inPlainText: text), passwordSource: text)
    }

    /// 去重 + 解析。同一地址只留一条;提取码优先取 URL 里的 `?pwd=`,其次正文的「提取码:xxxx」。
    private static func links(fromCandidates candidates: [String], passwordSource: String) -> [PanResourceLink] {
        var seen = Set<String>()
        var result: [PanResourceLink] = []
        let fallbackPassword = password(inPlainText: passwordSource)
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = PanResource.normalizeShareURL(trimmed)
            guard seen.insert(key).inserted else { continue }
            guard let cloudType = cloudType(of: trimmed) else { continue }
            let explicit = passwordFromURL(trimmed)
            result.append(PanResourceLink(
                url: trimmed,
                cloudType: cloudType,
                password: explicit ?? fallbackPassword))
        }
        return result
    }

    /// 认链接:网盘分享交给 `PanShareLink.parse`(只认确定域名),
    /// 磁力 / ed2k 没有 `PanShareLink` 形态,单独按 scheme 认。
    ///
    /// ⚠️ 磁力 / ed2k 转存不了(`PanCloudType.isTransferable == false`),但它们是资源,
    /// ⛔ 不能因为转存不了就吞掉(见 `PanResource` 的模型注释)。
    private static func cloudType(of raw: String) -> PanCloudType? {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("magnet:") { return .magnet }
        if lowered.hasPrefix("ed2k://") { return .ed2k }
        guard let parsed = PanShareLink.parse(raw) else { return nil }
        switch parsed {
        case .baidu, .pan115, .quark, .uc:
            return parsed.cloudType
        case .other(let type, _):
            // `.other` 只有认出具体网盘类型时才算(排除 unknown)
            return type == .unknown ? nil : type
        }
    }

    /// 正文里裸写的 URL。⛔ 不吃 `t.me` 自己的链接(频道互推 / 标签搜索页)。
    static func urls(inPlainText text: String) -> [String] {
        var found = captures(#"https?://[^\s<>"'）)，。；]+"#, in: text).filter { raw in
            guard let host = URL(string: raw)?.host()?.lowercased() else { return false }
            return host != "t.me" && host != "telegram.me"
        }
        found.append(contentsOf: captures(#"(?:magnet:\?[^\s<>"'）)，。；]+|ed2k://[^\s<>"'）)，。；]+)"#, in: text))
        return found
    }

    /// `?pwd=abcd` / `?password=abcd` / `#abcd`
    static func passwordFromURL(_ raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for name in ["pwd", "password", "passcode"] {
                if let value = items.first(where: { $0.name.lowercased() == name })?.value,
                   !value.isEmpty {
                    return value
                }
            }
        }
        if let fragment = url.fragment(), !fragment.isEmpty, !fragment.contains("/") {
            return fragment
        }
        return nil
    }

    /// 正文里的「提取码:abcd」/「访问码:abcd」/「密码:abcd」。
    static func password(inPlainText text: String) -> String? {
        firstCapture(
            #"(?:提取码|访问码|密码|提取碼)\s*[:：]\s*([A-Za-z0-9]{4,8})"#, in: text)
    }

    /// HTML → 纯文本。只做本模块要用的最小集合:`<br>` 变换行、去标签、反转义。
    static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        // 消息里嵌的 emoji 是 `<i class="emoji">📁</i>`,它的 `<b>` 里才是字符;去标签后保留文本
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return unescape(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescape(_ raw: String) -> String {
        let text = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        guard text.contains("&#") else { return text }
        // 数字实体(`&#128193;`):解得出就换,解不出原样留着,⛔ 不塞占位符
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "&#") {
            result += rest[rest.startIndex..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: ";") else {
                result += rest[start.lowerBound...]
                return result
            }
            let body = rest[start.upperBound..<end]
            let scalar: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalar = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(body)
            }
            if let scalar, let unicode = Unicode.Scalar(scalar) {
                result.append(Character(unicode))
                rest = rest[rest.index(after: end)...]
            } else {
                result += rest[start.lowerBound...end]
                rest = rest[rest.index(after: end)...]
            }
        }
        result += rest
        return result
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            // 模式可能没有捕获组(整段就是要的东西):取第 0 组
            let index = match.numberOfRanges > 1 ? 1 : 0
            guard let capture = Range(match.range(at: index), in: text) else { return nil }
            return String(text[capture])
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }}
