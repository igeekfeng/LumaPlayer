import Foundation

/// 搜索源适配器:把一种外部搜索接口的响应翻成 `[PanResource]`。
///
/// 一个 adapter 只管**一个源的一次搜索**,不发并发、不重试、不缓存 —— 那些在
/// `PanResourceSearchService` 里统一做,适配器越薄越好维护。
protocol ResourceSourceAdapter: Sendable {
    /// 与 `ResourceSourceAdapterKind` 一一对应,用于按配置分派
    var kind: ResourceSourceAdapterKind { get }

    /// 搜索。抛出的错误由调用方折成 `PanResourceSourceFailure`,⛔ 自己吞。
    func search(
        keyword: String,
        source: ResourceSource
    ) async throws -> [PanResource]
}

/// 适配器注册表:按 `ResourceSource.kind` 分派。
///
/// ⚠️ 拿不到 adapter 是**配置错误**,不是网络错误:要抛出去让用户看到
/// 「这条源的抓取方式本版本还不支持」,⛔ 不能静默返回空结果。
struct ResourceSourceAdapterRegistry: Sendable {
    private let adapters: [ResourceSourceAdapterKind: any ResourceSourceAdapter]

    init(adapters: [any ResourceSourceAdapter]) {
        var map: [ResourceSourceAdapterKind: any ResourceSourceAdapter] = [:]
        for adapter in adapters {
            map[adapter.kind] = adapter
        }
        self.adapters = map
    }

    func adapter(for source: ResourceSource) throws -> any ResourceSourceAdapter {
        guard let adapter = adapters[source.kind] else {
            throw PanResourceSearchError.unsupportedAdapter(
                sourceID: source.id, kind: source.kind)
        }
        return adapter
    }

    /// 本版本支持的抓取方式(设置页「新增源」的下拉项)
    var supportedKinds: [ResourceSourceAdapterKind] {
        ResourceSourceAdapterKind.allCases.filter { adapters[$0] != nil }
    }
}

enum PanResourceSearchError: Error, Equatable {
    /// 配置里的抓取方式本版本没有实现
    case unsupportedAdapter(sourceID: String, kind: ResourceSourceAdapterKind)
    /// 源没配置凭据
    case missingCredential(sourceID: String)
    /// 源返回的形状不认识
    case decoding(sourceID: String, detail: String)
    /// 源返回了错误(HTTP 状态码 / 业务错误码)
    case sourceFailed(sourceID: String, statusCode: Int?, message: String?)
    /// 关键词为空(不发请求)
    case emptyKeyword

    var userMessage: String {
        switch self {
        case .unsupportedAdapter(let sourceID, let kind):
            return "「\(sourceID)」的抓取方式(\(kind.displayName))本版本还不支持。"
        case .missingCredential(let sourceID):
            return "「\(sourceID)」需要先填凭据。"
        case .decoding(let sourceID, let detail):
            return "「\(sourceID)」返回的内容认不出来:\(detail)"
        case .sourceFailed(let sourceID, let statusCode, let message):
            let code = statusCode.map { "HTTP \($0)" } ?? "无状态码"
            if let message, !message.isEmpty {
                return "「\(sourceID)」返回错误(\(code)):\(message)"
            }
            return "「\(sourceID)」返回错误(\(code))。"
        case .emptyKeyword:
            return "关键词为空。"
        }
    }
}
