import Foundation

/// 一个「片库根」:百度应用目录**内部**的一个起点目录。
///
/// 它决定「进这个来源时先落在哪」—— 用户把片子按目录分好(电影 / 剧集 / 纪录片…),
/// 每个来源指一个,进来就直接落在那儿,不必每次从应用目录一层层点进去。
/// **一个来源只有一个片库根**(要两个起点就加两个来源 —— 授权是应用级的,
/// 多来源共用同一份 token,见 `AppContainer.addBaiduSource`)。
///
/// ⚠️ 它**不是授权范围**:第三方应用能访问的永远是 `/apps/{应用目录名}`
/// (`docs/BAIDU_PAN_API.md` §3),片库根只是那之内的一个书签。
/// 所以路径**每次读都要重新校验** —— 用户可能回头改了「应用目录名」
/// (改完旧路径整个失效),也可能在网盘里把那个子目录删了
/// (校验在 `BaiduPanConnection.libraryRoot(for:)`)。
///
/// ⚠️ 界面上它同时是**浏览页能退到的最外层**:片库根之上(应用目录那一层)
/// 不再露出 —— 那里看到的就是自己刚设的那个目录名,没有意义
/// (`BaiduPanSourceViewModel.canGoUp`)。
struct BaiduPanLibraryRoot: Codable, Sendable, Equatable {
    /// 网盘上的完整路径(`/apps/{应用目录名}/...`)
    var path: String

    /// 界面上显示的名字:路径最后一段(片库根只能是目录,所以最后一段必然有意义)。
    var displayName: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    init(path: String) {
        self.path = path
    }
}
