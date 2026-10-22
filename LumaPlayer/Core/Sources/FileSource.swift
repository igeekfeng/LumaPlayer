import Foundation

/// 文件树来源:只有目录树、没有服务端媒体结构(百度网盘 / 本地文件夹),共用 `FileSourceViewModel` 那套浏览页。
/// 差别只在下面几项能力上,浏览页按它分派,⛔ 不写 `if isBaidu`。
///
/// 是 `SourceProfile` 的子集,独立成类型让编译器挡住把 Emby 传进浏览页。
enum FileSource: Sendable, Equatable, Hashable {
    case baiduPan(BaiduPanSource)
    case localFolder(LocalFolderSource)

    var id: UUID {
        switch self {
        case .baiduPan(let source): return source.id
        case .localFolder(let source): return source.id
        }
    }

    var displayName: String {
        switch self {
        case .baiduPan(let source): return source.displayName
        case .localFolder(let source): return source.displayName
        }
    }

    func playbackSource(for file: BaiduPanFile) -> PlaybackSource {
        switch self {
        case .baiduPan: return .baiduPan(file: file)
        case .localFolder(let source): return .localFolder(file: file, source: source)
        }
    }

    /// 能不能连源文件一起删。本地文件夹只读(entitlement `files.user-selected.read-only`),只有「隐藏」。
    var supportsDeletingFiles: Bool {
        switch self {
        case .baiduPan: return true
        case .localFolder: return false
        }
    }

    /// 能不能按 TMDB 重命名整部剧(写操作)。
    var supportsRenamingSeries: Bool {
        switch self {
        case .baiduPan: return true
        case .localFolder: return false
        }
    }

    var storageNoun: String {
        switch self {
        case .baiduPan: return "网盘"
        case .localFolder: return "文件夹"
        }
    }
}
