import Foundation

/// 本地文件夹来源的错误。
///
/// 分两类处置(`needsFolderReselection`):
/// - **访问权没了**(书签解析不出 / 系统不给读 / 文件夹不在了):重试没用,
///   要让用户重新选一次文件夹(浏览页给「重新选择文件夹…」按钮);
/// - 其余(某一层读不出、某个文件被挪走):如实报原因,重试可能就好了。
enum LocalFolderError: Error, Equatable, Sendable {
    /// 书签解析失败:文件夹被删了、外接盘没插、网络卷没挂上
    case folderUnavailable(path: String)
    /// 书签解析出来了,但系统不给读(`startAccessingSecurityScopedResource` 返回 false)
    case accessDenied(path: String)
    /// 新选的文件夹做不出书签(多半是选了不允许的位置)
    case bookmarkCreationFailed(String)
    /// 某一层目录读不出来
    case directoryUnreadable(path: String, reason: String)
    /// 路径不在这个来源的目录树里(含 `..` 越界)。正常流程走不到,走到就是 bug
    case outsideRoot(path: String)
    /// 要播的文件不在了(列表之后被删 / 挪走)
    case fileMissing(name: String)
    /// 本地文件是直接交给内核按字节读的,没有「从某个位置起流」这件事
    case playbackUnsupported(String)
    /// 本地文件夹来源只读:不删、不改名(`FileSource.supportsDeletingFiles`)
    case readOnly

    /// 要不要让用户重新选文件夹(重试没用的那一类)。
    var needsFolderReselection: Bool {
        switch self {
        case .folderUnavailable, .accessDenied: return true
        case .bookmarkCreationFailed, .directoryUnreadable, .outsideRoot,
             .fileMissing, .playbackUnsupported, .readOnly:
            return false
        }
    }

    /// 给用户看的一句话。可以含本机路径(就是用户自己选的文件夹),⛔ 不含书签字节。
    var userMessage: String {
        switch self {
        case .folderUnavailable(let path):
            return "找不到文件夹「\(path)」。它可能被移动、删除,或者所在的磁盘还没接上。"
                + "接上磁盘后重试,或重新选择这个文件夹。"
        case .accessDenied(let path):
            return "没有读取「\(path)」的权限。请重新选择这个文件夹,授予 LumaPlayer 访问权限。"
        case .bookmarkCreationFailed(let reason):
            return "无法记住这个文件夹的访问权限:\(reason)"
        case .directoryUnreadable(let path, let reason):
            return "读取「\(path)」失败:\(reason)"
        case .outsideRoot(let path):
            return "路径「\(path)」不在这个来源的文件夹里。"
        case .fileMissing(let name):
            return "文件「\(name)」已经不在了(可能被移动或删除)。刷新列表后再试。"
        case .playbackUnsupported(let reason):
            return reason
        case .readOnly:
            return "本地文件夹来源是只读的,LumaPlayer 不会删除或改动你的文件。"
        }
    }
}

extension LocalFolderError: LocalizedError {
    var errorDescription: String? { userMessage }
}
