import Foundation

/// 夸克源的片库根:进入这个来源时先落在这个目录。
///
/// TV 端只有 fid 树、不提供路径(`docs/QUARK_API.md` §5.1),而浏览页 / 续播 / 剧集归属全都按路径串起来,
/// 所以这里存**虚拟路径**而不是 fid(`QuarkPath` 的说明)。路径 → fid 的换算由 `QuarkConnection`
/// 在内存里维护,失效了按路径重走一遍。
struct QuarkLibraryRoot: Codable, Sendable, Equatable {
    /// 从网盘根算起的虚拟路径,`"/"` 是根
    var path: String
    /// 目录名,只作展示;根目录是空串
    var name: String

    init(path: String, name: String) {
        self.path = QuarkPath.normalized(path)
        self.name = name
    }

    /// 夸克的根目录(fid `"0"`,§1)
    static let root = QuarkLibraryRoot(path: QuarkPath.root, name: "")

    var isRoot: Bool { path == Self.root.path }

    var displayName: String { isRoot ? "夸克网盘" : name }
}
