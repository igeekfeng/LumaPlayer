import Foundation

/// 一个库 / 目录在来源内的身份。
struct SourceLibraryRef: Sendable, Equatable, Hashable, Codable {
    let sourceID: UUID
    /// Emby 是 `View` 的 Id;百度是目录的绝对路径
    let libraryID: String
}

/// 来源里的一个「库」入口。
struct SourceLibrary: Sendable, Equatable, Hashable, Identifiable {
    let ref: SourceLibraryRef
    let title: String
    let kind: Kind

    enum Kind: String, Sendable, Equatable, Hashable {
        case movies
        case shows
        case music
        case mixed
        /// 普通目录(百度侧)
        case folder
    }

    var id: SourceLibraryRef { ref }

    /// Emby 的 `CollectionType` → 本枚举。
    /// ⛔ 不认识或缺失就是 `.mixed` —— 不猜(`API_CONTRACT.md` 3.2 同一条立场)。
    static func kind(forCollectionType type: String?) -> Kind {
        switch type?.lowercased() {
        case "movies": return .movies
        case "tvshows", "shows": return .shows
        case "music", "musicvideos": return .music
        default: return .mixed
        }
    }
}
