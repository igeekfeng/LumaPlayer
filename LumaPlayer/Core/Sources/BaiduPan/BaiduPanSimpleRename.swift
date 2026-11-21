import Foundation

/// 右键「重命名」的规则:`opera=rename` 只改**最后一段名字**(`docs/BAIDU_PAN_API.md` §2.5),
/// 所以只拦「空」「带 `/`」「和原名一样」三种,其余交给服务端。
///
/// 长度上限没有一手依据,⛔ 不自己编一个数字拦人;超了由服务端回错误码,走 `BaiduPanError` 的文案。
enum BaiduPanSimpleRename {

    enum Issue: Equatable {
        case empty
        case containsSlash
        case unchanged

        var message: String {
            switch self {
            case .empty: return "名字不能为空。"
            case .containsSlash: return "名字里不能有「/」:重命名只改最后一段,不挪位置。"
            case .unchanged: return "这和现在的名字一样。"
            }
        }
    }

    /// 去首尾空白。⛔ 不去中间的空白:那是用户自己写进去的。
    static func cleaned(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil = 可以提交。`original` 是网盘上现在的名字。
    static func issue(name raw: String, original: String) -> Issue? {
        let name = cleaned(raw)
        if name.isEmpty { return .empty }
        if name.contains("/") { return .containsSlash }
        if name == original { return .unchanged }
        return nil
    }
}
