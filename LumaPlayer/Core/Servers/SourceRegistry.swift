import Foundation

/// 来源注册表,存 `[SourceProfile]`(Emby 是其中一个 case)。旧名与错误类型在 `ServerRegistry.swift`。
///
/// - 列表持久化到 UserDefaults(`SourceProfile` 不含 token);
/// - 凭据语义在 `CredentialStore`,本类只在 `remove(id:)` 时联动删除该来源的 token / 密码。
actor SourceRegistry {
    static let storageKey = "SourceRegistry.profiles.v1"

    /// 旧格式 `[ServerProfile]` 的键,**只读**,用于迁移。⛔ 不要往这个键写东西。
    static let legacyEmbyStorageKey = "ServerRegistry.profiles.v1"

    private var sources: [SourceProfile]
    private let defaults: UserDefaults
    private let credentials: CredentialStore

    /// 读的顺序:新键 → 旧键(包成 `.emby(_)` 迁移,⛔ 不静默丢服务器)→ 空列表。
    /// 数据损坏时抛 `storageCorrupted`。
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

    /// 不读 UserDefaults(测试与「损坏后按空列表降级启动」用)。
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

    /// 合并式更新:`lastUsedAt` 保留库内现值,只有 `markUsed` 能改。
    /// 调用方拿的常是旧快照,整条替换会把旧时间写回去,导致启动恢复到错的来源。
    func update(_ source: SourceProfile) throws {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else {
            throw ServerRegistryError.notFound(source.id)
        }
        sources[index] = source.settingLastUsedAt(sources[index].lastUsedAt)
        try persist()
    }

    func mostRecentlyUsedSource() -> SourceProfile? {
        sources.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
    }

    /// 删除来源并清掉它的 token / 密码。幂等:来源已不存在也照样清凭证、不抛 notFound,
    /// 清凭证失败后可直接重试。
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

    // MARK: - Emby 便利入口

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
