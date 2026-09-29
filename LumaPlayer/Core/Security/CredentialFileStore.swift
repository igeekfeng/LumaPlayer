import Foundation

/// 凭据文件读写失败。
enum CredentialFileError: Error, Equatable {
    /// 文件存在但读不出来(权限、IO)
    case readFailed
    /// 文件存在但不是本类型写出的格式(被外部改坏)。
    /// ⛔ 不得就地重置成空文件:里面有全 App 唯一的 DeviceId(API_CONTRACT.md 2.4)
    case corrupted
    /// 落盘失败(建目录 / 写临时文件 / 原子替换 / 设置备份排除)
    case writeFailed
}

/// 服务器凭据(token、DeviceId)的本地文件存储。
/// actor 串行化访问(ARCHITECTURE.md 3.1.2:Core/Security 有状态类型是 actor)。
///
/// 不用 Keychain 的原因见 `docs/DECISIONS/credentials-file-storage.md`:
/// App 用 ad-hoc 签名,钥匙串 ACL 认 cdhash,每次重新构建都会弹授权窗。
/// 文件放在沙盒容器里,权限 0600,排除出 Time Machine 备份。
///
/// 只做原始键值存取,不含业务语义;token / DeviceId 的语义在 CredentialStore。
/// 路径可注入:测试用临时目录隔离,不碰真实容器。
actor CredentialFileStore {
    /// 旧版钥匙串导入。返回 account → 值;抛错 = 这次没导成(下次启动再试)。
    typealias LegacyImport = @Sendable () throws -> [String: Data]

    private let fileURL: URL
    private let legacyImport: LegacyImport?
    /// 已加载的文件内容。nil = 还没读过盘
    private var loaded: CredentialFile?
    /// 本次进程内导入失败的原因。记下来是为了不在每次存取时重试 ——
    /// 每次重试都会再弹一轮钥匙串授权窗。下次启动(新实例)才重试。
    private var legacyImportFailure: (any Error)?

    /// - Parameter legacyImport: 非 nil 时,文件里还没有「已导入」标记就先跑一次导入,
    ///   导入值不覆盖文件里已有的同名条目。
    init(fileURL: URL, legacyImport: LegacyImport? = nil) {
        self.fileURL = fileURL
        self.legacyImport = legacyImport
    }

    /// 生产路径:沙盒容器 `Library/Application Support/LumaPlayer/credentials.json`。
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaPlayer", directoryHint: .isDirectory)
            .appending(path: "credentials.json", directoryHint: .notDirectory)
    }

    /// 写入(已存在则覆盖,upsert 语义)。
    func setValue(_ value: Data, forAccount account: String) throws {
        var updated = try current()
        updated.entries[account] = value
        try commit(updated)
    }

    /// 读取;不存在返回 nil(不是错误)。
    func value(forAccount account: String) throws -> Data? {
        try current().entries[account]
    }

    /// 删除;不存在视为成功(幂等),且不落盘。
    func removeValue(forAccount account: String) throws {
        var updated = try current()
        guard updated.entries.removeValue(forKey: account) != nil else { return }
        try commit(updated)
    }

    /// 删除整个凭据文件(测试清理用)。
    func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // 本来就没有:幂等
        } catch {
            throw CredentialFileError.writeFailed
        }
        loaded = nil
        legacyImportFailure = nil
    }

    /// 原子 get-or-set:存在则返回现值;不存在则写入 `generator()` 的值并返回。
    /// 整段逻辑在 actor 隔离内同步完成(无 await),并发调用只生成一次
    /// —— DeviceId 的「全 App 唯一」依赖这一点(API_CONTRACT.md 2.4)。
    func value(forAccount account: String, defaultingTo generator: @Sendable () -> Data) throws -> Data {
        var updated = try current()
        if let existing = updated.entries[account] {
            return existing
        }
        let fresh = generator()
        updated.entries[account] = fresh
        try commit(updated)
        return fresh
    }

    // MARK: - 内部实现(actor 隔离内同步调用,不产生 await)

    /// 当前内容:首次访问时读盘,需要时先做旧版导入。
    private func current() throws -> CredentialFile {
        if let loaded {
            return loaded
        }
        var file = try readFile()
        if let legacyImport, !file.legacyKeychainImported {
            if let legacyImportFailure {
                throw legacyImportFailure
            }
            let imported: [String: Data]
            do {
                imported = try legacyImport()
            } catch {
                legacyImportFailure = error
                throw error
            }
            // 文件里已有的值优先:它们比钥匙串里的旧值新
            file.entries.merge(imported) { existing, _ in existing }
            file.legacyKeychainImported = true
            try writeFile(file)
        }
        loaded = file
        return file
    }

    /// 先落盘再更新内存:写失败时内存与磁盘保持一致。
    private func commit(_ file: CredentialFile) throws {
        try writeFile(file)
        loaded = file
    }

    private func readFile() throws -> CredentialFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CredentialFile()
        } catch {
            throw CredentialFileError.readFailed
        }
        do {
            return try JSONDecoder().decode(CredentialFile.self, from: data)
        } catch {
            throw CredentialFileError.corrupted
        }
    }

    /// 原子写:同目录下先写 0600 的临时文件,再 rename 覆盖。
    /// 不用 `Data.write(options: .atomic)`:它新建的文件按 umask 是 0644。
    private func writeFile(_ file: CredentialFile) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp", directoryHint: .notDirectory)
        let data: Data
        do {
            data = try JSONEncoder().encode(file)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CredentialFileError.writeFailed
        }
        guard fileManager.createFile(
            atPath: temporary.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CredentialFileError.writeFailed
        }
        guard rename(temporary.path(percentEncoded: false), fileURL.path(percentEncoded: false)) == 0 else {
            // 已经在抛错路径上:临时文件删不掉只是留个垃圾文件,下次写入会覆盖它
            try? fileManager.removeItem(at: temporary)
            throw CredentialFileError.writeFailed
        }
        // rename 换了新 inode,备份排除标记每次都要重新打
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        do {
            try target.setResourceValues(values)
        } catch {
            throw CredentialFileError.writeFailed
        }
    }
}

/// 凭据文件的磁盘格式。值是 `Data`,JSON 里编码为 base64。
private struct CredentialFile: Codable {
    /// 旧版钥匙串条目是否已导入过。只标记「做过」,不代表导入了什么
    var legacyKeychainImported = false
    var entries: [String: Data] = [:]
}
