import Foundation

extension URL {
    /// 每个用例一个独立的凭据文件路径,不碰真实沙盒容器里的那份。
    /// 文件由 `CredentialFileStore.removeAll()` 在 tearDown 删除。
    static func temporaryCredentialsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "LumaPlayerTests-credentials-\(UUID().uuidString).json", directoryHint: .notDirectory)
    }
}
