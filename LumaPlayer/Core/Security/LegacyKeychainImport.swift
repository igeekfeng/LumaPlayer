import Foundation
import Security

/// SecItem 返回非成功状态(errSecItemNotFound 不算)。授权窗点「拒绝」也是它。
struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// 钥匙串 generic-password 旧凭据的只读导入,由 `CredentialFileStore` 首次访问时调用。
/// 每读一条弹一次授权窗(ACL 认旧签名)。
///
/// ⛔ 不删旧条目:ad-hoc 删别的签名建的条目会被拒(-25244);DeviceId 那条留着兜底,
/// 凭据文件丢了会重新导入同一个值。
enum LegacyKeychainImport {
    static let defaultService = "com.local.LumaPlayer"

    /// 全有或全无:任何一条读失败都整体抛错。
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

    /// 只取属性,不取密文。
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
        // 类型对不上就抛错,不当成「没有条目」
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
