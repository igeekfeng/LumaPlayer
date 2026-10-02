import Foundation

extension EmbyView {
    /// 媒体库图标(首页「我的媒体」磁贴没有封面时的占位)。按 `CollectionType` 选,
    /// null / 未知类型用文件夹 —— 不猜它是什么库(API_CONTRACT.md 3.2)。
    var symbolName: String {
        switch collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "books": return "book"
        case "games": return "gamecontroller"
        case "homevideos", "musicvideos": return "video"
        case "livetv", "channels": return "antenna.radiowaves.left.and.right"
        default: return "folder"
        }
    }
}
