import Foundation
import Security

/// Keychain 原生操作失败:SecItem 返回了非成功状态
/// (errSecItemNotFound 在内部消化,不算错误)。
/// 用户在授权窗里点「拒绝」时就是这个错误。
struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// 旧版凭据(存在钥匙串 generic-password 里)的**只读**导入。
///
/// 凭据改存文件后(`docs/DECISIONS/credentials-file-storage.md`),钥匙串只在
/// 升级后第一次启动时读一次,由 `CredentialFileStore` 调用。
/// 每读一条条目,系统都会弹一次授权窗:旧条目的 ACL 认的是旧签名。
///
/// ⛔ 不删旧条目:ad-hoc 签名的程序删别的签名建的条目会被拒(实测 -25244),
/// 而且 DeviceId 那条留着可以兜底 —— 凭据文件丢了会从这里重新导入同一个值。
enum LegacyKeychainImport {
    static let defaultService = "com.local.LumaPlayer"

    /// 读出 `service` 下 account 满足 `isWanted` 的全部条目。
    /// 任何一条读失败都整体抛错(全有或全无),不返回残缺结果。
    static func values(
        service: String = defaultService,
        where isWanted: (String) -> Bool
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for account in try accounts(service: service) where isWanted(account) {
            if let value = try value(service: service, account: account) {
                result[account] = value
            }
        }
        return result
    }

    /// 列出 service 下全部 account(只取属性,不取密文)。
    private static func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError(status: status)
        }
        // 返回类型对不上就是 Security 框架行为变了:抛错,不当成「没有条目」
        guard let items = result as? [[String: Any]] else {
            throw KeychainError(status: errSecDecode)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func value(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError(status: errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }
}
