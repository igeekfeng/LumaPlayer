import Foundation

/// 图片数据加载。抽象成协议是为了让缓存层可以脱离网络单测。
protocol ImageDataLoading: Sendable {
    func data(for spec: ImageSpec) async throws -> Data
    func data(for descriptor: ImageDescriptor) async throws -> Data
}

extension ImageDataLoading {
    /// 默认实现:只认 Emby 端点,其余 origin 走不通。
    ///
    /// 之所以给默认实现:测试替身只关心「被调了几次、返回什么字节」,
    /// 让它们为了协议完整性再写一遍 `switch` 是纯噪音。
    /// 生产实现 `PosterImageLoader` 覆写本方法,三种 origin 都支持。
    func data(for descriptor: ImageDescriptor) async throws -> Data {
        guard case .emby(let spec) = descriptor.origin else {
            throw PosterImageError.unsupportedOrigin
        }
        return try await data(for: spec)
    }
}

/// 取图片字节(actor)。
///
/// 三条通路(见 `ImageDescriptor.Origin`):
/// - `.emby` → 经 `ServerConnection` 走 Emby 图片端点(要认证头,`API_CONTRACT.md` 3.3);
/// - `.remote` → 普通 `URLSession` 请求(百度 `dlink` 自带 `access_token`,
///   但**必须带与 sign 绑定的 UA**,见 `docs/BAIDU_PAN_API.md` §1);
/// - `.localFile` → 直接读盘。
///
/// ⛔ 不管走哪条,**只有 `Components/PosterImage.swift` 能触发它** ——
/// 视图自己发图片请求会在认证 / 缓存 / 失败处置上各写一套。
actor PosterImageLoader: ImageDataLoading {
    private let container: AppContainer
    /// 远程图片用的会话。默认 `.shared`;测试注入 `MockEmbyURLProtocol` 时传同一个。
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
                // `dlink` 过期后是 403,不是「服务器坏了」—— 由上层决定重取还是降级
                throw PosterImageError.badResponse(status: http.statusCode)
            }
            return data

        case .localFile(let url):
            return try Data(contentsOf: url)
        }
    }
}
