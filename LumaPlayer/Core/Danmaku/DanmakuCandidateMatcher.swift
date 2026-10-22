import Foundation

/// 从 `/match` 的模糊候选里挑出唯一确定的那一集(`docs/DANMAKU.md` §3;文件名匹配模糊候选很常见,Q45)。
///
/// 集号 / 季 / 类型三道硬门槛 + 标题包含关系软校验,过完必须恰好剩一个,否则返回 nil 交给用户。
/// ⛔ 不自动取第一个模糊结果;⛔ 不改成加权打分:阈值偏低就会把「第二季第 5 话」判给「第一季第 5 话」。
enum DanmakuCandidateMatcher {

    /// 目标这一集的已知事实。nil = 不知道,⛔ 不补默认值。
    struct Target: Sendable, Equatable {
        let title: String?
        /// 正片集号;电影 / 认不出时为 nil
        let episodeNumber: Int?
        let seasonNumber: Int?
        let isFinalSeason: Bool
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

    /// 没有或不止一个返回 nil。
    static func uniqueMatch(in candidates: [DanmakuCandidate], target: Target) -> DanmakuCandidate? {
        guard !candidates.isEmpty else { return nil }
        // 电影没有集号可比,但类型与标题仍是门槛:⛔ 不能因候选只剩一条就把剧集当成这部电影
        if target.isMovie {
            let survivors = candidates.filter { isConsistent($0, with: target) }
            return survivors.count == 1 ? survivors[0] : nil
        }
        let survivors = candidates.filter { isConsistent($0, with: target) }
        return survivors.count == 1 ? survivors[0] : nil
    }

    static func isConsistent(_ candidate: DanmakuCandidate, with target: Target) -> Bool {
        guard typeMatches(candidate, isMovie: target.isMovie) else { return false }
        guard seasonMatches(candidate, target: target) else { return false }
        guard episodeMatches(candidate, target: target) else { return false }
        return titleMatches(candidate, target: target)
    }

    // MARK: - 集号(硬)

    /// 集号必须相等;特典(`S1` / `C1`)与正片是不同命名空间,不算命中。
    private static func episodeMatches(_ candidate: DanmakuCandidate, target: Target) -> Bool {
        guard let wanted = target.episodeNumber else { return true }
        guard let token = DanmakuEpisodeToken.parse(candidate.episodeTitle) else { return false }
        return token.numberValue == wanted
    }

    // MARK: - 季(硬)

    /// 候选认不出季按第 1 季(弹弹play 只有多季才在标题写季号);目标季未知不判断。
    /// 「最终季」单独比:它是独立作品,标题季号常仍是 1。
    private static func seasonMatches(_ candidate: DanmakuCandidate, target: Target) -> Bool {
        let parsed = season(in: candidate.animeTitle)
        if parsed.isFinal != target.isFinalSeason { return false }
        guard let wanted = target.seasonNumber else { return true }
        return (parsed.number ?? 1) == wanted
    }

    /// 解析 `第2季` / `第二季` / `S2` / `Season 2` / `最终季`。
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

    /// 剧场版与剧集是不同作品。`type` 缺失时不判断(⛔ 不假设成剧集)。
    private static func typeMatches(_ candidate: DanmakuCandidate, isMovie: Bool) -> Bool {
        guard let type = candidate.type?.lowercased() else { return true }
        let candidateIsMovie = movieTypes.contains(type)
        return candidateIsMovie == isMovie
    }

    /// AnimeType 里属于电影的项。
    private static let movieTypes: Set<String> = ["movie", "jpmovie", "tmdbmovie"]

    // MARK: - 标题(软)

    /// 归一后互相包含即同一部。任一边为空不通过:⛔ 不能只靠集号撞上就采用。
    private static func titleMatches(_ candidate: DanmakuCandidate, target: Target) -> Bool {
        guard let wanted = target.title, !wanted.isEmpty,
              let candidateTitle = candidate.animeTitle, !candidateTitle.isEmpty
        else { return false }
        let a = comparable(wanted)
        let b = comparable(candidateTitle)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// 全角转半角、小写、只留字母与数字。
    static func comparable(_ title: String) -> String {
        var result = ""
        for character in DanmakuEpisodeToken.normalize(title).lowercased()
        where character.isLetter || character.isNumber {
            result.append(character)
        }
        return result
    }
}
