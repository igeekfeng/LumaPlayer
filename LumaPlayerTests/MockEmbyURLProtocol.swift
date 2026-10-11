import Foundation
import os

/// 测试用 URLProtocol:按「scheme + path」返回预设响应,并记录收到的请求。
///
/// 目的:让集成测试**零真实网络依赖**。
///
/// 静态状态用 `OSAllocatedUnfairLock` 保护:URLProtocol 的回调在任意线程同步执行,
/// 进不了 actor(不能 await),也 ⛔ 不允许用 `nonisolated(unsafe)`
/// (CLAUDE.md「并发分层」全项目禁止)。
final class MockEmbyURLProtocol: URLProtocol {
    /// 预设响应
    struct Stub: Sendable {
        enum Outcome: Sendable {
            case response(statusCode: Int, body: Data?)
            case failure(URLError.Code)
        }

        let outcome: Outcome

        /// 200 + JSON 字符串
        static func json(_ body: String, statusCode: Int = 200) -> Stub {
            Stub(outcome: .response(statusCode: statusCode, body: Data(body.utf8)))
        }

        /// 只关心状态码(如 401 —— Emby 的鉴权失败响应通常没有 body)
        static func status(_ code: Int) -> Stub {
            Stub(outcome: .response(statusCode: code, body: nil))
        }

        static func failure(_ code: URLError.Code) -> Stub {
            Stub(outcome: .failure(code))
        }
    }

    /// 记录下来的请求(用于断言请求头与 body)
    struct RecordedRequest: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            // HTTP 头名大小写不敏感,统一按小写比较
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private struct State: Sendable {
        /// 同一路径可排多条:按顺序逐条消耗,最后一条一直重复
        var stubs: [String: [Stub]] = [:]
        var requests: [RecordedRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - 测试侧 API

    /// 预设一条响应。默认 https + emby.test —— 探测的 http 回退用例要显式传 scheme,
    /// 多服务器隔离用例要显式传 host。
    static func stub(
        _ stub: Stub,
        scheme: String = "https",
        host: String = "emby.test",
        path: String
    ) {
        state.withLock { $0.stubs[key(scheme: scheme, host: host, path: path)] = [stub] }
    }

    /// 同一路径依次返回 `stubs` 里的响应(如先 401 再 200),用完后重复最后一条。
    static func stub(
        sequence stubs: [Stub],
        scheme: String = "https",
        host: String = "emby.test",
        path: String
    ) {
        precondition(!stubs.isEmpty)
        state.withLock { $0.stubs[key(scheme: scheme, host: host, path: path)] = stubs }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func recordedRequests() -> [RecordedRequest] {
        state.withLock { $0.requests }
    }

    /// 最后一次匹配该 path 后缀的请求(用于断言认证头/请求体)。
    static func lastRequest(matchingPathSuffix suffix: String) -> RecordedRequest? {
        state.withLock { $0.requests.last { $0.url.path.hasSuffix(suffix) } }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    private static func key(scheme: String, host: String, path: String) -> String {
        "\(scheme)|\(host)|\(path)"
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            fail(with: URLError(.badURL))
            return
        }
        let record = RecordedRequest(
            method: request.httpMethod ?? "",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            // URLProtocol 拿到的 request 里 httpBody 常被置空、改由
            // httpBodyStream 提供(URLSession 的行为),两边都要读。
            body: request.httpBody ?? Self.streamBody(request.httpBodyStream)
        )
        let stub = Self.state.withLock { state -> Stub? in
            state.requests.append(record)
            let key = Self.key(scheme: url.scheme ?? "", host: url.host() ?? "", path: url.path)
            guard var queue = state.stubs[key], let first = queue.first else { return nil }
            if queue.count > 1 {
                queue.removeFirst()
                state.stubs[key] = queue
            }
            return first
        }
        guard let stub else {
            // 没有预设 = 这条路径不该被请求到。返回 404 而不是让请求真的发出去,
            // 这样「探测试了哪个前缀」会在 recordedRequests 里留下痕迹。
            respond(statusCode: 404, body: nil)
            return
        }
        switch stub.outcome {
        case .response(let statusCode, let body):
            respond(statusCode: statusCode, body: body)
        case .failure(let code):
            fail(with: URLError(code))
        }
    }

    override func stopLoading() {}

    // MARK: - 内部

    private func respond(statusCode: Int, body: Data?) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            fail(with: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body, !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(with error: URLError) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private static func streamBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
