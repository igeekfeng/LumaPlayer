import Foundation

/// 片库根:百度应用目录内部的起点目录,进这个来源时先落在这里。一个来源只有一个
/// (要两个起点就加两个来源,多来源共用同一份 token,见 `AppContainer.addBaiduSource`)。
///
/// 它不是授权范围(永远是 `/apps/{应用目录名}`,`docs/BAIDU_PAN_API.md` §3),只是其中的书签,
/// 所以每次读都要重新校验(应用目录名可能改了、子目录可能删了,见 `BaiduPanConnection.libraryRoot(for:)`)。
/// 它也是浏览页能退到的最外层(`FileSourceViewModel.canGoUp`)。
struct BaiduPanLibraryRoot: Codable, Sendable, Equatable {
    /// `/apps/{应用目录名}/...`
    var path: String

    /// 路径最后一段。
    var displayName: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    init(path: String) {
        self.path = path
    }
}
