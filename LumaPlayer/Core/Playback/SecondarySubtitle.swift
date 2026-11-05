import Foundation

/// 副字幕(`secondary-sid`,MPV_INTEGRATION.md 7.5):可选的轨与位置 / 字号。纯函数,无 mpv 依赖。
///
/// mpv 不会把两路字幕自动堆起来:`secondary-sub-pos` 只是把副字幕按画面高度百分比整体上移
/// (`sd_ass.c` → `ass_set_line_position(100 - pos)`),默认 0 = 贴顶,正好压在弹幕区上。
/// 所以这里按主字幕的字号与位置算一个**固定**位置,给主字幕预留两行;
/// ⛔ 不按 `sub-lines` 逐句算 —— 每句改一次位置,副字幕会跟着主字幕行数上下跳。
enum SecondarySubtitle {

    // MARK: - 可选的轨

    /// 能当副字幕的轨:文本字幕,且不是当前主字幕。
    /// 图形字幕(PGS / VobSub …)不吃 `secondary-sub-pos`,永远画在原位,会与主字幕重叠(options.rst `--secondary-sid`);
    /// 同一条轨同时当主副,mpv 会拒绝(`loadfile.c` 「Track N is already selected」)。
    static func candidates(in tracks: [MPVTrack], primaryID: Int?) -> [MPVTrack] {
        tracks.filter { $0.isTextSubtitle && $0.id != primaryID }
    }

    // MARK: - 位置与字号

    /// 副字幕字号相对主字幕的比例(「小一档」)。
    /// 副字幕走 `strip` = 完全覆盖样式,字号只看 `secondary-sub-scale`,不乘 `sub-scale`,所以要换算成绝对值。
    static let scaleRatio = 0.8
    /// 给主字幕预留的行数:常见的对白最多两行;三行时会压到副字幕底部,接受。
    static let reservedPrimaryLines = 2.0
    /// mpv `--sub-font-size` 默认 38(本 App 不改),单位是 720 高画面下的 scaled pixel。
    static let fontSize = 38.0
    static let referenceHeight = 720.0
    /// 行高 / 字号:libass 行高 ≈ 字体 ascent + descent,中文字体约 1.2,再算上描边。估算值,未视觉验证(KNOWN_ISSUES.md Q56)。
    static let lineHeightFactor = 1.25
    /// 主副字幕之间的空隙,占画面高度的百分比
    static let gapPercent = 1.0
    /// mpv `--secondary-sub-pos` 的取值范围
    static let positionRange: ClosedRange<Double> = 0...150

    /// 主字幕一行占画面高度的百分比。`sub-scale-with-window` 默认开,字号跟画面高度走,所以与窗口大小无关。
    static func primaryLineHeightPercent(scale: Double) -> Double {
        fontSize * lineHeightFactor / referenceHeight * 100 * scale
    }

    /// `secondary-sub-pos`:主字幕位置再往上让出 `reservedPrimaryLines` 行 + 空隙。
    /// 两者同一个基准(都是从原始底边上移 `100 - pos`),所以直接相减。
    static func position(for style: SubtitleStyle) -> Double {
        let primary = style.clamped
        let reserved = reservedPrimaryLines * primaryLineHeightPercent(scale: primary.scale) + gapPercent
        return min(max(primary.position - reserved, positionRange.lowerBound), positionRange.upperBound)
    }

    /// `secondary-sub-scale`
    static func scale(for style: SubtitleStyle) -> Double {
        style.clamped.scale * scaleRatio
    }

    /// 与主字幕外观一起设(`MPVPlayer.setSubtitleProperties`)。没选副字幕时设了也无副作用。
    /// `secondary-sub-ass-override=strip` 是 mpv 默认,显式写上:平移与字号都靠它成立
    /// (`strip` 把副字幕当纯文本、套 `--sub-*` 样式;ASS 原样渲染时 `secondary-sub-pos` 不一定生效)。
    static func mpvProperties(for style: SubtitleStyle) -> [(name: String, value: String)] {
        [
            ("secondary-sub-ass-override", "strip"),
            ("secondary-sub-scale", SubtitleStyle.number(scale(for: style))),
            ("secondary-sub-pos", SubtitleStyle.number(position(for: style))),
        ]
    }
}
