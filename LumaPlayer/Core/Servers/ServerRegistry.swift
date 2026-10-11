import Foundation

/// 旧名保留。
///
/// `ServerRegistry` 曾是一个只装 Emby 档案的 actor,现已泛化为
/// `SourceRegistry`(见 `Core/Servers/SourceRegistry.swift`)。旧名在本文件里
/// 以别名形式保留:10 个测试文件与既有代码按 `ServerRegistry(...)` /
/// `ServerRegistry.storageKey` 使用,改造**不动它们**
/// (见 `docs/SOURCE_ABSTRACTION_PLAN.md` §6.2)。
typealias ServerRegistry = SourceRegistry

/// 来源注册表的错误。
///
/// ⚠️ 名字里的 `Server` 是历史遗留:错误语义对**所有**来源一样,
/// 改名会牵连一批 `catch let error as ServerRegistryError`,收益为零。
/// 因此保留 `ServerRegistryError` 这个名字。
enum ServerRegistryError: Error, Equatable {
    /// add 时已存在同 id 的来源
    case duplicateServer(UUID)
    /// update / markUsed 找不到该来源
    case notFound(UUID)
    /// UserDefaults 里的列表数据无法解码(损坏)。init 抛出,
    /// 由上层决定呈现方式,不静默吞掉。
    case storageCorrupted
}
