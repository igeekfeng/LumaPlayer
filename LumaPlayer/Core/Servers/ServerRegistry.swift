import Foundation

/// `SourceRegistry` 的旧名,测试与既有代码按 `ServerRegistry(...)` / `ServerRegistry.storageKey` 使用。
typealias ServerRegistry = SourceRegistry

/// 来源注册表的错误(名字里的 `Server` 是历史名,语义对所有来源一样)。
enum ServerRegistryError: Error, Equatable {
    case duplicateServer(UUID)
    /// update / markUsed 找不到该来源
    case notFound(UUID)
    /// UserDefaults 里的列表无法解码。init 抛出,由上层决定呈现,不静默吞掉。
    case storageCorrupted
}
