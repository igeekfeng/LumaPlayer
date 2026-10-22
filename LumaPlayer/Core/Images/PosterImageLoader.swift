import Foundation

/// 抽成协议让缓存层可以脱离网络单测。
protocol ImageDataLoading: Sendable {
    func data(for spec: ImageSpec) async throws -> Data
    func data(for descriptor: ImageDescriptor) async throws -> Data
}

extension ImageDataLoading {
    /// 默认只认 Emby 端点,省得测试替身各写一遍 `switch`;`PosterImageLoader` 覆写支持全部 origin。
    func data(for descriptor: ImageDescriptor) async throws -> Data {
        guard case .emby(let spec) = descriptor.origin else {
            throw PosterImageError.unsupportedOrigin
        }
        return try await data(for: spec)
    }
}

/// 取图片字节。`.emby` 经 `ServerConnection`(要认证头);`.remote` 普通请求,但百度 `dlink`
/// 必须带与 sign 绑定的 UA(`docs/BAIDU_PAN_API.md` §1,由 `headers` 给);`.localFile` 直接读盘。
/// ⛔ 只有 `Components/PosterImage.swift` 能触发它。
actor PosterImageLoader: ImageDataLoading {
    private let container: AppContainer
    /// 测试注入 `MockEmbyURLProtocol` 时传同一个会话
    private let session: URLSession

    init(container: AppContainer, session: URLSession = .shared) {
        self.container = container
        self.session = session
    }

    func data(for spec: ImageSpec) async throws -> Data {
        guard let profile = await container.profile(id: spec.serverID) else {
            throw EmbyAPIError.notFound
        }
        let connection = await container.connection(for: profile)
        return try await connection.imageData(
            itemID: spec.itemID,
            type: spec.type,
            tag: spec.tag,
            maxWidth: spec.maxWidth
        )
    }

    func data(for descriptor: ImageDescriptor) async throws -> Data {
        switch descriptor.origin {
        case .emby(let spec):
            return try await data(for: spec)

        case .remote(let url, let headers):
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // `dlink` 过期是 403,由上层决定重取还是降级
                throw PosterImageError.badResponse(status: http.statusCode)
            }
            return data

        case .localFile(let url):
            return try Data(contentsOf: url)
        }
    }
}
