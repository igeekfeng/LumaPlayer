import Foundation

/// 服务器注册表的错误。
enum ServerRegistryError: Error, Equatable {
    /// add 时已存在同 id 的服务器
    case duplicateServer(UUID)
    /// update / markUsed 找不到该服务器
    case notFound(UUID)
    /// UserDefaults 里的列表数据无法解码(损坏)。init 抛出,
    /// 由上层决定呈现方式,不静默吞掉。
    case storageCorrupted
}

/// 多服务器注册表(actor,见 ARCHITECTURE.md 6.1)。
///
/// - profiles 持久化到 UserDefaults(ServerProfile 不含 token,见模型注释);
/// - token / DeviceId 的存取语义在 CredentialStore,本类只在
///   `remove(id:)` 时联动删除该服务器的 token —— 这也是 `remove` 是
///   `async throws` 的原因:CredentialStore 是 actor,跨 actor 调用隐式异步。
actor ServerRegistry {
    /// 持久化键。带 v1 后缀,日后格式变更时可迁移。
    static let storageKey = "ServerRegistry.profiles.v1"

    private var profiles: [ServerProfile]
    private let defaults: UserDefaults
    private let credentials: CredentialStore

    /// 从 UserDefaults 恢复;数据损坏时抛 `storageCorrupted`。
    init(defaults: UserDefaults = .standard, credentials: CredentialStore) throws {
        self.defaults = defaults
        self.credentials = credentials
        guard let data = defaults.data(forKey: Self.storageKey) else {
            self.profiles = []
            return
        }
        do {
            self.profiles = try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            throw ServerRegistryError.storageCorrupted
        }
    }

    /// 直接给定初始 profiles,不读 UserDefaults
    /// (测试与「损坏后按空列表降级启动」用)。
    init(profiles: [ServerProfile], defaults: UserDefaults = .standard, credentials: CredentialStore) {
        self.profiles = profiles
        self.defaults = defaults
        self.credentials = credentials
    }

    func all() -> [ServerProfile] {
        profiles
    }

    func add(_ profile: ServerProfile) throws {
        guard !profiles.contains(where: { $0.id == profile.id }) else {
            throw ServerRegistryError.duplicateServer(profile.id)
        }
        profiles.append(profile)
        try persist()
    }

    /// 合并式更新:写入调用方给的字段,但 `lastUsedAt` 保留库内现值。
    ///
    /// 不做整条替换,是因为调用方拿到的 profile 往往是一份**快照**
    /// (列表视图读一次后就留在 `@State` 里),而 `markUsed` 会在快照之后
    /// 改动库内的 `lastUsedAt`。整条替换会把旧快照的时间写回去 ——
    /// 表现为「切到 A 再编辑 A,下次启动恢复的却是 B」。
    /// 因此 `lastUsedAt` 归注册表独占,只有 `markUsed` 能改。
    func update(_ profile: ServerProfile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ServerRegistryError.notFound(profile.id)
        }
        var merged = profile
        merged.lastUsedAt = profiles[index].lastUsedAt
        profiles[index] = merged
        try persist()
    }

    /// 删除服务器,并同步清掉它在凭据文件里的 token。
    ///
    /// 幂等:服务器已不存在时仍会尝试清凭证、不抛 notFound ——
    /// 这样「persist 成功但清凭证失败」后直接重试 remove 即可补清。
    func remove(id: UUID) async throws {
        profiles.removeAll { $0.id == id }
        try persist()
        try await credentials.deleteToken(forServer: id)
    }

    func mostRecentlyUsed() -> ServerProfile? {
        profiles.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
    }

    func markUsed(id: UUID, at date: Date) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ServerRegistryError.notFound(id)
        }
        profiles[index].lastUsedAt = date
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: Self.storageKey)
    }
}
