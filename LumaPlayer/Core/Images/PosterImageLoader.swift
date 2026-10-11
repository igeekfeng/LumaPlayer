import Foundation

/// 图片数据加载。抽象成协议是为了让缓存层可以脱离网络单测。
protocol ImageDataLoading: Sendable {
    func data(for spec: ImageSpec) async throws -> Data
}

/// 经 `EmbyAPIClient` 取图片(actor:持有 `ServerConnection`,
/// CLAUDE.md「并发分层」的分层规则)。
///
/// 图片端点要走和 JSON 一样的认证头与状态码映射
/// (`API_CONTRACT.md` 3.3、第 7 节),这也是它不能交给
/// `Components/PosterImage.swift` 之外的视图自己发的原因。
actor PosterImageLoader: ImageDataLoading {
    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
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
}
