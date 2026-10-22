import Foundation

/// **文件树来源**:只有一棵目录树、没有服务端媒体结构的那一类来源(百度网盘 / 本地文件夹)。
///
/// 它们共用一个浏览页(`FileSourceViewModel` / `FileSourceBrowserView` /
/// `FileSourceSeriesDetailView`):列目录 → 本地合成条目 → TMDB 刮削 → 剧集详情 →
/// 本地续播。差别只在这里列出的几项能力上,浏览页按它分派,⛔ 不写 `if isBaidu`。
///
/// 与 `SourceProfile` 的关系:那个是**全部**来源的身份(含 Emby),这个是它的子集 ——
/// 浏览页只该收到能按目录浏览的来源,做成独立类型编译器就能挡住「把 Emby 传进来」。
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

    /// 播放这条文件的请求来源。
    func playbackSource(for file: BaiduPanFile) -> PlaybackSource {
        switch self {
        case .baiduPan: return .baiduPan(file: file)
        case .localFolder(let source): return .localFolder(file: file, source: source)
        }
    }

    /// 能不能连源文件一起删(浏览页「删除…」里那个开关)。
    ///
    /// 本地文件夹**只读**:书签按只读申请(entitlement `files.user-selected.read-only`),
    /// 删本机文件也不是一个播放器该做的事 —— 那一路只有「隐藏」。
    var supportsDeletingFiles: Bool {
        switch self {
        case .baiduPan: return true
        case .localFolder: return false
        }
    }

    /// 能不能「按 TMDB 重命名」整部剧(改的是源文件名,同样是写操作)。
    var supportsRenamingSeries: Bool {
        switch self {
        case .baiduPan: return true
        case .localFolder: return false
        }
    }

    /// 文案里「文件放在哪」的说法:「网盘」/「文件夹」。
    var storageNoun: String {
        switch self {
        case .baiduPan: return "网盘"
        case .localFolder: return "文件夹"
        }
    }
}
