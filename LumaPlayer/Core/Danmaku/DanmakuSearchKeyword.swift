import Foundation

/// 手动搜索的输入整理(`DanmakuPickerSheet`)。
///
/// `/search/episodes` 的 `anime` 只按作品名匹配(`docs/DANDANPLAY_API.md` §3),关键词里带 `S01E01` 这类
/// 集号标记就一条都搜不到(danmu_api 实测:`暗潮之下 S01E01` 0 条,`暗潮之下` + `episode=1` 命中)。
/// 用户顺手照文件名的习惯写集号很常见,所以把**末尾**的集号标记剥出来放进 `episode`。
///
/// 只认末尾、且与作品名之间有分隔的标记:`S01E01` / `S1 E1` / `E01` / `EP01` / `第1集`(话 / 話 / 回 / 期)。
/// 剥完不足 2 个字(接口下限)就原样不动。
///
/// 接口没有季参数:季号只用来在本地筛结果(`groups(_:inSeason:)`)。
enum DanmakuSearchKeyword {

    struct Parts: Equatable {
        let title: String
        let episode: Int?
        /// 只有 `S02E05` 这种写法带季号
        var season: Int? = nil
    }

    static func split(_ keyword: String) -> Parts {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 前面必须是空白或 `.` `-` `_`,⛔ 不从作品名中间切(`WALLE2` 这类名字不动)
        if let match = trimmed.firstMatch(of: /[\s._\-](?:S(?<season>\d{1,2})\s*)?EP?\s*(?<episode>\d{1,4})$/.ignoresCase()),
           let parts = parts(trimmed, cutAt: match.range.lowerBound, episode: match.output.episode,
                             season: match.output.season)
        {
            return parts
        }
        if let match = trimmed.firstMatch(of: /\s*第\s*(?<episode>\d{1,4})\s*[集话話回期]$/),
           let parts = parts(trimmed, cutAt: match.range.lowerBound, episode: match.output.episode, season: nil)
        {
            return parts
        }
        return Parts(title: trimmed, episode: nil)
    }

    private static func parts(
        _ text: String, cutAt index: String.Index, episode: Substring, season: Substring?
    ) -> Parts? {
        guard let episode = Int(episode), episode > 0 else { return nil }
        let title = String(text[..<index]).trimmingCharacters(in: separators)
        guard title.count >= 2 else { return nil }
        return Parts(title: title, episode: episode, season: season.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil })
    }

    /// 手动搜索框的预填值:去掉年份(Emby 剧名常是 `暗潮之下 (2026)`)。年份对 `anime` 只有干扰,
    /// 同名不同年的作品在结果里看 `animeTitle` 区分。
    ///
    /// 认括号里的年份(`(2026)` / `（2026）` / `[2026]`,任意位置)与末尾以分隔符隔开的裸年份(`Some.Show.2026`)。
    /// 去完不足 2 个字(片名就是年份,如 `1917`)就原样返回。
    static func removingYear(_ title: String) -> String {
        var result = title.replacing(/\s*[(（\[【]\s*(?:19|20)\d{2}\s*[)）\]】]/, with: "")
        result = result.replacing(/[\s._\-](?:19|20)\d{2}$/, with: "")
        result = result.trimmingCharacters(in: separators)
        return result.count >= 2 ? result : title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-_"))

    /// 按季号筛搜索结果。季号认法同 `DanmakuCandidateMatcher.season(in:)`:标题没写季 = 第 1 季
    /// (弹弹play 只有多季才在标题写季号)。`season` 为 nil 不筛。
    static func groups(_ groups: [DanmakuSearchGroup], inSeason season: Int?) -> [DanmakuSearchGroup] {
        guard let season else { return groups }
        return groups.filter { (DanmakuCandidateMatcher.season(in: $0.animeTitle).number ?? 1) == season }
    }
}
