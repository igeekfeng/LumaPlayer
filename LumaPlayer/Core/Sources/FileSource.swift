import Foundation

/// 文件树来源:只有目录树、没有服务端媒体结构(百度网盘 / 115 网盘 / 本地文件夹),共用 `FileSourceViewModel` 那套浏览页。
/// 差别只在下面几项能力上,浏览页按它分派,⛔ 不写 `if isBaidu`。
///
/// 是 `SourceProfile` 的子集,独立成类型让编译器挡住把 Emby 传进浏览页。
enum FileSource: Sendable, Equatable, Hashable {
    case baiduPan(BaiduPanSource)
    case pan115(Pan115Source)
    case localFolder(LocalFolderSource)

    var id: UUID {
        switch self {
        case .baiduPan(let source): return source.id
        case .pan115(let source): return source.id
        case .localFolder(let source): return source.id
        }
    }

    var displayName: String {
        switch self {
        case .baiduPan(let source): return source.displayName
        case .pan115(let source): return source.displayName
        case .localFolder(let source): return source.displayName
        }
    }

    func playbackSource(for file: BaiduPanFile) -> PlaybackSource {
        switch self {
        case .baiduPan: return .baiduPan(file: file)
        case .pan115: return .pan115(file: file)
        case .localFolder(let source): return .localFolder(file: file, source: source)
        }
    }

    /// 能不能连源文件一起删。本地文件夹只读(entitlement `files.user-selected.read-only`),只有「隐藏」;
    /// 百度与 115 都能删(115 走 `POST /rb/delete`,进的是回收站,见 `docs/PAN115_API.md` §9)。
    var supportsDeletingFiles: Bool {
        switch self {
        case .baiduPan, .pan115: return true
        case .localFolder: return false
        }
    }

    /// 真删之后在网盘端还能不能恢复。只决定删除确认面板的措辞,⛔ 不是「删了没删」的判据。
    ///
    /// - 115:`/rb/delete` 会把内容移进**回收站**(§9),可以在 115 网页端还原。
    /// - 百度:按「不可撤销」告知用户(`docs/BAIDU_PAN_API.md` §2.4,删除是递归的)。
    var remoteDeletionIsRecoverable: Bool {
        switch self {
        case .pan115: return true
        case .baiduPan, .localFolder: return false
        }
    }

    /// 能不能按 TMDB 重命名整部剧(写操作)。改名只有百度做了;115 的改名接口没接(§7)。
    var supportsRenamingSeries: Bool {
        switch self {
        case .baiduPan: return true
        case .pan115: return false
        case .localFolder: return false
        }
    }

    var storageNoun: String {
        switch self {
        case .baiduPan: return "网盘"
        case .pan115: return "网盘"
        case .localFolder: return "文件夹"
        }
    }
}
