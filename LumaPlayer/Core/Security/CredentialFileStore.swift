import Foundation

/// 凭据文件读写失败。
enum CredentialFileError: Error, Equatable {
    /// 文件存在但读不出来(权限、IO)
    case readFailed
    /// ⛔ 不得就地重置成空文件:里面有全 App 唯一的 DeviceId(API_CONTRACT.md 2.4)
    case corrupted
    case writeFailed
}

/// 凭据(token、DeviceId 等)的本地文件存储,只做原始键值存取,语义在 `CredentialStore`。
///
/// 不用 Keychain:ad-hoc 签名的钥匙串 ACL 认 cdhash,每次构建都弹授权窗;加显式 DR 也没用,
/// data protection keychain 又要 provisioning profile。
/// 文件在沙盒容器里,值 base64(不是加密),权限 0600(先写 0600 临时文件再 `rename`,
/// 不用 `.atomic` —— 它按 umask 建 0644),每次写完重打 `isExcludedFromBackup`(rename 换了 inode)。
///
/// 安全取舍:防不住同一用户身份、能读容器的进程;ad-hoc 没有稳定代码身份,不弹窗的加密都防不住,
/// 所以不加密。密码只在用户勾了「记住密码」时才存。
///
/// 迁移:首次访问且没有「已导入」标记时,从旧钥匙串(service `com.local.LumaPlayer`)导入
/// `deviceId` 与 `server-token:*`(每条弹一次授权窗);全有或全无,失败本进程不重试;
/// 文件里已有的同名值优先。⛔ 不删旧条目(见 `LegacyKeychainImport`)。
actor CredentialFileStore {
    /// 返回 account → 值;抛错 = 没导成,下次启动再试。
    typealias LegacyImport = @Sendable () throws -> [String: Data]

    private let fileURL: URL
    private let legacyImport: LegacyImport?
    /// nil = 还没读过盘
    private var loaded: CredentialFile?
    /// 本进程不重试导入(每次重试都弹一轮授权窗),下次启动才重试。
    private var legacyImportFailure: (any Error)?

    init(fileURL: URL, legacyImport: LegacyImport? = nil) {
        self.fileURL = fileURL
        self.legacyImport = legacyImport
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaPlayer", directoryHint: .isDirectory)
            .appending(path: "credentials.json", directoryHint: .notDirectory)
    }

    func setValue(_ value: Data, forAccount account: String) throws {
        var updated = try current()
        updated.entries[account] = value
        try commit(updated)
    }

    /// 不存在返回 nil(不是错误)。
    func value(forAccount account: String) throws -> Data? {
        try current().entries[account]
    }

    /// 幂等;不存在时不落盘。
    func removeValue(forAccount account: String) throws {
        var updated = try current()
        guard updated.entries.removeValue(forKey: account) != nil else { return }
        try commit(updated)
    }

    /// 测试清理用。
    func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // 幂等
        } catch {
            throw CredentialFileError.writeFailed
        }
        loaded = nil
        legacyImportFailure = nil
    }

    /// 原子 get-or-set。整段同步完成(⛔ 不得引入 await),并发调用只生成一次 ——
    /// DeviceId 全 App 唯一依赖这点(API_CONTRACT.md 2.4)。
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
            // 文件里的值比钥匙串的新,优先
            file.entries.merge(imported) { existing, _ in existing }
            file.legacyKeychainImported = true
            try writeFile(file)
        }
        loaded = file
        return file
    }

    /// 先落盘再更新内存,写失败时两者一致。
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
            // 已在抛错路径上,删不掉的临时文件下次写入会覆盖
            try? fileManager.removeItem(at: temporary)
            throw CredentialFileError.writeFailed
        }
        // rename 换了 inode,每次重打
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

/// 磁盘格式。`Data` 在 JSON 里是 base64。
private struct CredentialFile: Codable {
    /// 只标记「做过」,不代表导入了什么
    var legacyKeychainImported = false
    var entries: [String: Data] = [:]
}
