import Foundation

/// 弹弹play 分集标题里的「第几集」,以及特典用的字母命名空间(`docs/DANDANPLAY_API.md` §4 / §5)。
///
/// ## 为什么需要它
///
/// `/match` 返回模糊候选时,`episodeTitle` 是**唯一**能把候选对到具体某一集的字段
/// (`episodeId` 只是弹幕库编号,本身不含集数语义)。而它的形状很杂:
/// `第5话 没用的魔法` / `05` / `EP06` / `第十二话` / `S2 圣地巡礼` / `C1 OP`。
///
/// 只做「集号相等」这一件事,**故意不猜**:
/// - 不把「标题里出现过这个数字」当成命中(`S5 圣地巡礼` 里的 5 不是第 5 话);
/// - 解析不出来就返回 nil,由调用方退回「让用户挑」,⛔ 不给默认值。
///
/// 命名空间依据官方规格(`BangumiEpisode.episodeNumber` 与 `search/episodes` 的
/// `episode` 参数):「非纯数字,可能包含字母」,`episode` 参数接受 `C1` / `S1` / `O1`。
enum DanmakuSpecialKind: String, Sendable, Equatable, CaseIterable {
    /// 特典 / 特别篇 / 圣地巡礼
    case special = "S"
    /// Opening / Ending 等附属影像
    case extra = "C"
    /// 发布会、警告等其他
    case other = "O"
}

/// 一集的编号:正片集数,或特典的「命名空间 + 序号」。
enum DanmakuEpisodeToken: Sendable, Equatable {
    case number(Int)
    case special(kind: DanmakuSpecialKind, index: Int)

    /// 正片集数(特典为 nil)
    var numberValue: Int? {
        if case .number(let value) = self { return value }
        return nil
    }
}

extension DanmakuEpisodeToken {

    /// 从分集标题解析集号。解析不出返回 nil(**不猜**)。
    ///
    /// 顺序:字母命名空间 → `第 N 话/集/回/期` → 中文数字 → 行首 `EP`/`E`/裸数字。
    /// 先判字母命名空间是刻意的:`S2 …` 若先走「行首数字」会把 2 当成第 2 话。
    static func parse(_ title: String?) -> DanmakuEpisodeToken? {
        guard let title else { return nil }
        let text = normalize(title)
        guard !text.isEmpty else { return nil }

        if let token = parseSpecialPrefix(text) { return token }
        if let value = parseNumberedEpisode(text) { return .number(value) }
        if let value = parseChineseEpisode(text) { return .number(value) }
        if let value = parseLeadingNumber(text) { return .number(value) }
        return nil
    }

    // MARK: - 各形态

    /// 行首 `S` / `C` / `O` + 1-3 位数字,后面不能再跟字母或数字。
    ///
    /// 末尾那条约束挡的是两种真实形态:
    /// - `S01E05`(季集写法)里的 `S01` 不是特典 1;
    /// - `S2 圣地巡礼` 里的 `S2` 后面是空格,是特典 2。
    private static func parseSpecialPrefix(_ text: String) -> DanmakuEpisodeToken? {
        let characters = Array(text)
        guard let first = characters.first, characters.count >= 2 else { return nil }
        let upper = String(first).uppercased()
        guard let kind = DanmakuSpecialKind(rawValue: upper) else { return nil }
        var index = 1
        var digits = ""
        while index < characters.count, characters[index].isNumber, digits.count < 3 {
            digits.append(characters[index])
            index += 1
        }
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        if index < characters.count {
            let next = characters[index]
            guard !next.isNumber, !next.isLetter else { return nil }
        }
        return .special(kind: kind, index: value)
    }

    /// `第 5 话` / `第5集` / `第 3 回` / `第2期`(全角已归一)。
    /// 「第」与数字之间允许空格(`第 02 集`)。
    private static func parseNumberedEpisode(_ text: String) -> Int? {
        guard let range = text.range(of: "第") else { return nil }
        var index = range.upperBound
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        var digits = ""
        while index < text.endIndex, text[index].isNumber, digits.count < 4 {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }
        return Self.episodeSuffixes.contains(text[index]) ? value : nil
    }

    /// `第十二话`。中文数字里 `十` 不是「一位数字」,但必须能出现在扫描里
    /// (`十二` 的首字就是它),所以扫描用 `isChineseNumeral` 而不是查表。
    private static func parseChineseEpisode(_ text: String) -> Int? {
        guard let range = text.range(of: "第") else { return nil }
        var index = range.upperBound
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        var digits = ""
        while index < text.endIndex, isChineseNumeral(text[index]), digits.count < 3 {
            digits.append(text[index])
            index = text.index(after: index)
        }
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard !digits.isEmpty, index < text.endIndex, Self.episodeSuffixes.contains(text[index]) else {
            return nil
        }
        return chineseNumber(digits)
    }

    /// 行首 `EP06` / `E06` / `05` / `5 标题`
    ///
    /// 只认**行首**:标题中间的数字(`葬送的芙莉莲 2 期 第 5 话` 已由前一条命中;
    /// 而 `Re:0 从零开始的异世界生活` 这种名字里的数字不该被当集号)。
    private static func parseLeadingNumber(_ text: String) -> Int? {
        var index = text.startIndex
        // 可选前缀 EP / E(大小写不敏感)
        let lowered = text.lowercased()
        if lowered.hasPrefix("ep") {
            index = text.index(text.startIndex, offsetBy: 2)
        } else if lowered.hasPrefix("e"), text.count > 1 {
            let next = text[text.index(after: text.startIndex)]
            if next.isNumber { index = text.index(after: text.startIndex) }
        }
        var digits = ""
        var cursor = index
        while cursor < text.endIndex, text[cursor].isNumber, digits.count < 4 {
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        // 数字后必须是结尾或分隔符:`1080p` 之类不算集号
        if cursor < text.endIndex {
            let next = text[cursor]
            guard !next.isLetter else { return nil }
        }
        return value
    }

    // MARK: - 字符工具

    /// `话` / `集` / `回` / `期`(简繁都收)
    private static let episodeSuffixes: Set<Character> = ["话", "話", "集", "回", "期"]

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    /// 中文数字位:**含 `十`**。`chineseDigits` 里刻意没有 `十`,
    /// 因为它的数值取决于位置(十位还是个位),由 `chineseNumber` 单独处理。
    private static func isChineseNumeral(_ character: Character) -> Bool {
        character == "十" || chineseDigits[character] != nil
    }

    /// 中文数字 0-99(只覆盖「十二」「二十」「二十一」这类集号写法)
    static func chineseNumber(_ text: String) -> Int? {
        if text == "十" { return 10 }
        guard !text.isEmpty else { return nil }
        let characters = Array(text)
        if let tenIndex = characters.firstIndex(of: "十") {
            let tens = tenIndex == 0 ? 1 : (chineseDigits[characters[tenIndex - 1]] ?? -1)
            let ones = tenIndex == characters.count - 1 ? 0 : (chineseDigits[characters[tenIndex + 1]] ?? -1)
            guard tens >= 0, ones >= 0 else { return nil }
            return tens * 10 + ones
        }
        guard characters.count == 1 else { return nil }
        return chineseDigits[characters[0]]
    }

    /// 全角数字 / 全角空格归一,并去首尾空白。
    static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF10...0xFF19:  // 全角 0-9
                if let converted = UnicodeScalar(scalar.value - 0xFEE0) { result.append(Character(converted)) }
            case 0x3000:  // 全角空格
                result.append(" ")
            default:
                result.append(Character(scalar))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
