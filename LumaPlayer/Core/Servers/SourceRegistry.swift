import Foundation

/// 来源注册表(actor,见 CLAUDE.md「每台服务器完全隔离」)。
///
/// 由旧的 `ServerRegistry`(只装 Emby)泛化而来:现在存的是 `[SourceProfile]`,
/// Emby 只是其中一个 case。**Emby 侧的 API 与行为保持不变** —— 旧代码与
/// 10 个测试文件按 `ServerRegistry` / `ServerProfile` 使用,改造不动它们
/// (旧名与错误类型的家在 `ServerRegistry.swift`)。
///
/// - 列表持久化到 UserDefaults(`SourceProfile` 不含 token,见模型注释);
/// - token / 密码 / DeviceId 的存取语义在 `CredentialStore`,本类只在
///   `remove(id:)` 时联动删除该来源的凭据 —— 这也是 `remove` 是
///   `async throws` 的原因:CredentialStore 是 actor,跨 actor 调用隐式异步。
actor SourceRegistry {
    /// 当前持久化键。带 v1 后缀,日后格式变更时可迁移。
    static let storageKey = "SourceRegistry.profiles.v1"

    /// 改造前的旧键:只存 `[ServerProfile]`。**只读**,用于一次性迁移。
    /// ⛔ 不要往这个键写东西 —— 写它会与迁移逻辑打架,也会让
    /// `testUserDefaultsDumpContainsNoToken` 之外的行为不可预期。
    static let legacyEmbyStorageKey = "ServerRegistry.profiles.v1"

    private var sources: [SourceProfile]
    private let defaults: UserDefaults
    private let credentials: CredentialStore

    /// 从 UserDefaults 恢复;数据损坏时抛 `storageCorrupted`。
    ///
    /// 读的顺序:新键 → 旧键(迁移)→ 空列表。旧键里是改造前存下的
    /// `[ServerProfile]`,包一层成 `.emby(_)` 即可 —— ⛔ 不静默丢服务器。
    init(defaults: UserDefaults = .standard, credentials: CredentialStore) throws {
        self.defaults = defaults
        self.credentials = credentials
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                self.sources = try JSONDecoder().decode([SourceProfile].self, from: data)
            } catch {
                throw ServerRegistryError.storageCorrupted
            }
            return
        }
        if let legacy = defaults.data(forKey: Self.legacyEmbyStorageKey) {
            do {
                let profiles = try JSONDecoder().decode([ServerProfile].self, from: legacy)
                self.sources = profiles.map(SourceProfile.emby)
            } catch {
                throw ServerRegistryError.storageCorrupted
            }
            return
        }
        self.sources = []
    }

    /// 直接给定初始 profiles,不读 UserDefaults
    /// (测试与「损坏后按空列表降级启动」用)。Emby 便利构造。
    init(profiles: [ServerProfile], defaults: UserDefaults = .standard, credentials: CredentialStore) {
        self.sources = profiles.map(SourceProfile.emby)
        self.defaults = defaults
        self.credentials = credentials
    }

    // MARK: - 通用(来源无关)

    func allSources() -> [SourceProfile] {
        sources
    }

    func add(_ source: SourceProfile) throws {
        guard !sources.contains(where: { $0.id == source.id }) else {
            throw ServerRegistryError.duplicateServer(source.id)
        }
        sources.append(source)
        try persist()
    }

    /// 合并式更新:写入调用方给的字段,但 `lastUsedAt` 保留库内现值。
    ///
    /// 不做整条替换,是因为调用方拿到的往往是一份**快照**
    /// (列表视图读一次后就留在 `@State` 里),而 `markUsed` 会在快照之后
    /// 改动库内的 `lastUsedAt`。整条替换会把旧快照的时间写回去 ——
    /// 表现为「切到 A 再编辑 A,下次启动恢复的却是 B」。
    /// 因此 `lastUsedAt` 归注册表独占,只有 `markUsed` 能改。
    func update(_ source: SourceProfile) throws {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else {
            throw ServerRegistryError.notFound(source.id)
        }
        sources[index] = source.settingLastUsedAt(sources[index].lastUsedAt)
        try persist()
    }

    /// 最近使用的来源(任意类型)。`currentSource` 恢复用它。
    func mostRecentlyUsedSource() -> SourceProfile? {
        sources.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
    }

    /// 删除来源,并同步清掉它在凭据文件里的 token / 密码。
    ///
    /// 幂等:来源已不存在时仍会尝试清凭证、不抛 notFound ——
    /// 这样「persist 成功但清凭证失败」后直接重试 remove 即可补清。
    func remove(id: UUID) async throws {
        sources.removeAll { $0.id == id }
        try persist()
        try await credentials.deleteToken(forServer: id)
        try await credentials.deletePassword(forServer: id)
    }

    func markUsed(id: UUID, at date: Date) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            throw ServerRegistryError.notFound(id)
        }
        sources[index] = sources[index].settingLastUsedAt(date)
        try persist()
    }

    // MARK: - Emby 便利入口(等价于对 .emby 泛化入口的封装)

    func all() -> [ServerProfile] {
        sources.compactMap { source in
            if case .emby(let profile) = source { return profile }
            return nil
        }
    }

    func add(_ profile: ServerProfile) throws {
        try add(SourceProfile.emby(profile))
    }

    func update(_ profile: ServerProfile) throws {
        try update(SourceProfile.emby(profile))
    }

    func mostRecentlyUsed() -> ServerProfile? {
        let emby = all()
        return emby.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
    }

    // MARK: - 私有

    private func persist() throws {
        let data = try JSONEncoder().encode(sources)
        defaults.set(data, forKey: Self.storageKey)
    }
}
