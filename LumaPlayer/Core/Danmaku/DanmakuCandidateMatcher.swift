import Foundation

/// 从 `/match` 的模糊候选里挑出**唯一确定**的那一集(`docs/DANMAKU.md` §3)。
///
/// ## 为什么要有它
///
/// 现在的行为是「`isMatched` 才自动采用,否则一律让用户挑」。但 `/match` 走的是
/// **文件名**匹配(Emby 甚至只有合成名,`KNOWN_ISSUES.md` Q45),模糊候选很常见;
/// 而其中相当一部分其实是**唯一确定**的 —— 候选里只有一集集号对得上,其余都不对。
/// 这种情况让用户再点一次没有信息增量。
///
/// ## 边界:只做「唯一才采用」
///
/// 与 `DANMAKU.md` §3「⛔ 不自动取第一个模糊结果」同一条立场,只是把「候选里有没有
/// 唯一答案」这件事算清楚:
///
/// - 三个硬门槛(**集号 / 季 / 类型**)任一不通过就出局,不给「差不多」的余地;
/// - 标题只做**包含关系**的软校验,不做相似度打分;
/// - 过完全部门槛后**必须恰好剩一个**,剩 0 个或 ≥2 个都返回 nil(交回用户)。
///
/// 刻意不做 OcPlayer 那套加权打分(集数 +2000 / 季度 +1500 / 标题 +1500 …)。
/// 加权打分要调阈值,而阈值一旦偏低就会把「第二季第 5 话」判给「第一季第 5 话」;
/// 唯一性判据没有阈值可调,错判面更小。
enum DanmakuCandidateMatcher {

    /// 目标这一集的已知事实。字段缺失即「不知道」,⛔ 不补默认值。
    struct Target: Sendable, Equatable {
        /// 作品名(用于标题软校验);nil = 不知道
        let title: String?
        /// 正片集号;电影 / 认不出集号时为 nil
        let episodeNumber: Int?
        /// 季号;nil = 不知道
        let seasonNumber: Int?
        /// 目标是最终季
        let isFinalSeason: Bool
        /// 目标是电影(与剧集互斥,`API_CONTRACT.md` 4.1 的条目类型)
        let isMovie: Bool

        init(
            title: String? = nil,
            episodeNumber: Int? = nil,
            seasonNumber: Int? = nil,
            isFinalSeason: Bool = false,
            isMovie: Bool = false
        ) {
            self.title = title
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.isFinalSeason = isFinalSeason
            self.isMovie = isMovie
        }
    }

    /// 返回**唯一**确定的候选;没有或不止一个返回 nil。
    static func uniqueMatch(in candidates: [DanmakuCandidate], target: Target) -> DanmakuCandidate? {
        guard !candidates.isEmpty else { return nil }
        // 电影没有集号可比,但**类型与标题仍是硬门槛**:剧场版与剧集是不同作品,
        // 不能因为「候选只剩一条」就把剧集候选当成这部电影的弹幕。
        if target.isMovie {
            let survivors = candidates.filter { isConsistent($0, with: target) }
            return survivors.count == 1 ? survivors[0] : nil
        }
        let survivors = candidates.filter { isConsistent($0, with: target) }
        return survivors.count == 1 ? survivors[0] : nil
    }

    /// 单个候选是否与目标一致。三道硬门槛 + 一道软校验。
    static func isConsistent(_ candidate: DanmakuCandidate, with target: Target) -> Bool {
        guard typeMatches(candidate, isMovie: target.isMovie) else { return false }
        guard seasonMatches(candidate, target: target) else { return false }
        guard episodeMatches(candidate, target: target) else { return false }
        return titleMatches(candidate, target: target)
    }

    // MARK: - 集号(硬)

    /// 目标有集号时,候选的集号必须**相等**;特典(`S1` / `C1`)与正片是不同命名空间,
    /// 一律不算命中。
    private static func episodeMatches(_ candidate: DanmakuCandidate, target: Target) -> Bool {
        guard let wanted = target.episodeNumber else { return true }
        guard let token = DanmakuEpisodeToken.parse(candidate.episodeTitle) else { return false }
        return token.numberValue == wanted
    }

    // MARK: - 季(硬)

    /// 目标季已知时,候选季必须一致。
    ///
    /// 候选**认不出季**时按第 1 季处理(弹弹play 的作品标题只有多季才会写「第二季」)。
    /// 目标季未知(nil)时不做判断 —— 不知道就不猜。
    ///
    /// 「最终季」单独判:弹弹play 把最终季写成独立作品,标题里的季号常常仍是 1,
    /// 只比季号会把「最终季」和「第一季」当成同一部。
    private static func seasonMatches(_ candidate: DanmakuCandidate, target: Target) -> Bool {
        let parsed = season(in: candidate.animeTitle)
        if parsed.isFinal != target.isFinalSeason { return false }
        guard let wanted = target.seasonNumber else { return true }
        return (parsed.number ?? 1) == wanted
    }

    /// 从作品标题解析季号。`第2季` / `第二季` / `S2` / `Season 2` / `最终季`。
    ///
    /// `isFinal` 单独给出:弹弹play 把「最终季」写成独立作品标题,季号常常仍是 1。
    static func season(in title: String?) -> (number: Int?, isFinal: Bool) {
        guard let title else { return (nil, false) }
        let text = DanmakuEpisodeToken.normalize(title)
        let isFinal = text.contains("最终季") || text.lowercased().contains("final season")
        if let number = firstNumber(after: ["第"], before: ["季", "期", "部"], in: text) {
            return (number, isFinal)
        }
        if let number = chineseSeason(in: text) { return (number, isFinal) }
        if let number = firstNumber(after: ["season ", "season"], before: [], in: text, caseInsensitive: true) {
            return (number, isFinal)
        }
        if let number = seasonPrefix(in: text) { return (number, isFinal) }
        return (nil, isFinal)
    }

    /// `第 2 季` / `第2期`
    private static func firstNumber(
        after prefixes: [String], before suffixes: [String], in text: String,
        caseInsensitive: Bool = false
    ) -> Int? {
        let haystack = caseInsensitive ? text.lowercased() : text
        for prefix in prefixes {
            guard let range = haystack.range(of: prefix) else { continue }
            var index = range.upperBound
            var digits = ""
            while index < haystack.endIndex, haystack[index].isNumber, digits.count < 2 {
                digits.append(haystack[index])
                index = haystack.index(after: index)
            }
            guard !digits.isEmpty, let value = Int(digits), value > 0 else { continue }
            if suffixes.isEmpty { return value }
            guard index < haystack.endIndex, suffixes.contains(String(haystack[index])) else { continue }
            return value
        }
        return nil
    }

    /// `第二季`
    private static func chineseSeason(in text: String) -> Int? {
        guard let range = text.range(of: "第") else { return nil }
        var index = range.upperBound
        var digits = ""
        while index < text.endIndex, digits.count < 3,
              DanmakuEpisodeToken.chineseNumber(String(digits + String(text[index]))) != nil {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard !digits.isEmpty, index < text.endIndex, ["季", "期", "部"].contains(text[index]) else {
            return nil
        }
        return DanmakuEpisodeToken.chineseNumber(digits)
    }

    /// `S2` / `S02`,必须是独立 token(避免 `MS2` 之类误判)。
    private static func seasonPrefix(in text: String) -> Int? {
        let characters = Array(text)
        for index in characters.indices where characters[index] == "S" || characters[index] == "s" {
            if index > 0 {
                let previous = characters[index - 1]
                guard !previous.isLetter, !previous.isNumber else { continue }
            }
            var cursor = index + 1
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber, digits.count < 2 {
                digits.append(characters[cursor])
                cursor += 1
            }
            guard !digits.isEmpty, let value = Int(digits), value > 1 else { continue }
            // 后面紧跟 E 是 `S01E05`,那是季集写法,同样算季号
            return value
        }
        return nil
    }

    // MARK: - 类型(硬)

    /// 剧场版与剧集是**不同作品**,不是偏好(`MatchResultV2.type`,AnimeType 枚举)。
    /// `type` 缺失时不做判断(规格里它可空,⛔ 不假设成剧集)。
    private static func typeMatches(_ candidate: DanmakuCandidate, isMovie: Bool) -> Bool {
        guard let type = candidate.type?.lowercased() else { return true }
        let candidateIsMovie = movieTypes.contains(type)
        return candidateIsMovie == isMovie
    }

    /// AnimeType 里属于「电影」的三项(官方枚举:tvseries / tvspecial / ova / movie /
    /// musicvideo / web / other / jpmovie / jpdrama / unknown / tmdbtv / tmdbmovie)。
    private static let movieTypes: Set<String> = ["movie", "jpmovie", "tmdbmovie"]

    // MARK: - 标题(软)

    /// 归一后互相包含即视为同一部作品。任何一边为空都不通过 ——
    /// 标题都没有时无从判断「是不是同一部」,不能靠集号撞上就采用。
    private static func titleMatches(_ candidate: DanmakuCandidate, target: Target) -> Bool {
        guard let wanted = target.title, !wanted.isEmpty,
              let candidateTitle = candidate.animeTitle, !candidateTitle.isEmpty
        else { return false }
        let a = comparable(wanted)
        let b = comparable(candidateTitle)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// 比较用的归一形态:全角转半角、小写、只留字母与数字。
    static func comparable(_ title: String) -> String {
        var result = ""
        for character in DanmakuEpisodeToken.normalize(title).lowercased()
        where character.isLetter || character.isNumber {
            result.append(character)
        }
        return result
    }
}
