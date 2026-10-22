import Foundation

/// 弹弹play 特典的字母命名空间(`docs/DANDANPLAY_API.md` §4 / §5,`episode` 参数接受 `C1` / `S1` / `O1`)。
enum DanmakuSpecialKind: String, Sendable, Equatable, CaseIterable {
    /// 特典 / 特别篇 / 圣地巡礼
    case special = "S"
    /// Opening / Ending 等附属影像
    case extra = "C"
    /// 发布会、警告等其他
    case other = "O"
}

/// 从分集标题解析的编号:正片集数,或特典「命名空间 + 序号」。
///
/// `episodeTitle` 是唯一能把模糊候选对到某一集的字段(`episodeId` 不含集数语义),形状很杂:
/// `第5话 没用的魔法` / `05` / `EP06` / `第十二话` / `S2 圣地巡礼` / `C1 OP`。
/// 故意不猜:「标题里出现过这个数字」不算命中;解析不出返回 nil,⛔ 不给默认值。
enum DanmakuEpisodeToken: Sendable, Equatable {
    case number(Int)
    case special(kind: DanmakuSpecialKind, index: Int)

    /// 特典为 nil
    var numberValue: Int? {
        if case .number(let value) = self { return value }
        return nil
    }
}

extension DanmakuEpisodeToken {

    /// 顺序:字母命名空间 → `第 N 话/集/回/期` → 中文数字 → 行首 `EP`/`E`/裸数字。
    /// 字母命名空间必须先判,否则 `S2 …` 会被当成第 2 话。
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

    /// 行首 `S` / `C` / `O` + 1-3 位数字,后面不能跟字母或数字(`S01E05` 不是特典 1)。
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

    /// `第十二话`。扫描用 `isChineseNumeral`(含 `十`)而不是查 `chineseDigits`。
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

    /// 行首 `EP06` / `E06` / `05` / `5 标题`。只认行首:作品名里的数字(`Re:0`)不是集号。
    private static func parseLeadingNumber(_ text: String) -> Int? {
        var index = text.startIndex
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

    /// 简繁都收
    private static let episodeSuffixes: Set<Character> = ["话", "話", "集", "回", "期"]

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    /// 含 `十`。`chineseDigits` 刻意没有 `十`:它的数值取决于位置,由 `chineseNumber` 处理。
    private static func isChineseNumeral(_ character: Character) -> Bool {
        character == "十" || chineseDigits[character] != nil
    }

    /// 0-99,只覆盖「十二」「二十」「二十一」这类集号写法
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
