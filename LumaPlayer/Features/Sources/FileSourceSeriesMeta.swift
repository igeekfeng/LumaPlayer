import Foundation

/// 剧集详情页标题下那行元信息的纯展示逻辑(不带 SwiftUI,便于单测)。
/// 季数 / 集数只在这里出现一次:「信息」区不再重复列,也不带来源前缀。
enum FileSourceSeriesMeta {

    /// - Parameters:
    ///   - year: 首播年份
    ///   - seasons: 季数。只有一季时整段不显示(很多剧就一季,「共 1 季」没有信息量)
    ///   - episodes: 全剧集数
    /// - Returns: 依次拼好的文案段,缺哪段就不出现哪段(⛔ 不留空占位、不拿别的字段凑)
    static func parts(year: Int?, seasons: Int?, episodes: Int?) -> [String] {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let seasons, seasons > 1 { parts.append("共 \(seasons) 季") }
        if let episodes, episodes > 0 { parts.append("共 \(episodes) 集") }
        return parts
    }
}
