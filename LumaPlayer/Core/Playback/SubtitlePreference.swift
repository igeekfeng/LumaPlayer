import Foundation

/// 起播时的字幕模式(本地偏好,所有服务器共用)。与 Emby `UserConfiguration.SubtitleMode` 同名但无关:
/// 不读写该配置(未在 `API_CONTRACT.md` 核实)。
enum SubtitleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }

    /// 默认:简中 → 繁中 → 未标变体的中文 → 不动 mpv 默认
    case smart
    /// 没有中文字幕时开第一条字幕轨
    case always
    /// 只开强制字幕(`track-list/N/forced`);没有就关
    case forcedOnly
    /// 起播不开(播放中仍可手动开)
    case none

    var label: String {
        switch self {
        case .smart: "中文优先"
        case .always: "总是开字幕"
        case .forcedOnly: "只开强制字幕"
        case .none: "起播不开字幕"
        }
    }

    /// 设置页 footer
    var detail: String {
        switch self {
        case .smart: "有简体中文选简体,没有再找繁体;都没有就交给 mpv 的默认轨。"
        case .always: "优先中文字幕,一条中文都没有时打开第一条字幕轨。"
        case .forcedOnly: "只显示标记为「强制」的字幕(通常是外语对白的那几句);没有强制轨就关掉字幕。"
        case .none: "每次起播都关闭字幕,想看时自己在控制栏的字幕菜单里开。"
        }
    }
}

enum SubtitleStartupChoice: Equatable, Sendable {
    /// 保持 mpv 自己选的轨
    case leaveAlone
    /// `sid = no`
    case off
    case track(id: Int)
}

/// 起播字幕偏好:简体 → 繁体 → 未标变体的中文(排在明确繁体之后)→ 判不出返回 nil。
///
/// 自己判而不用 mpv 的 `slang`:它只认语言码,简繁常都标 `chi`,区分靠 `title`;
/// 且 `MPVPlayer` 设了 `config=no`。⛔ 判不出不猜,保持 mpv 的 default 轨,
/// 不能把英文字幕当中文选上。
enum SubtitlePreference {

    /// nil = 保持 mpv 的 `sid=auto`。同一档内取 `id` 最小的。
    static func preferredTrackID(in tracks: [MPVTrack]) -> Int? {
        var traditional: Int?
        var unspecifiedChinese: Int?

        for track in tracks.filter({ $0.type == .sub }).sorted(by: { $0.id < $1.id }) {
            switch chineseVariant(of: track) {
            case .simplified:
                return track.id          // 已按 id 升序
            case .traditional:
                traditional = traditional ?? track.id
            case .unspecified:
                unspecifiedChinese = unspecifiedChinese ?? track.id
            case nil:
                continue
            }
        }
        return traditional ?? unspecifiedChinese
    }

    enum ChineseVariant: Equatable {
        case simplified
        case traditional
        /// 是中文,但简繁未知
        case unspecified
    }

    /// `.smart` 判不出中文时 `.leaveAlone`,`.always` 才退到第一条轨;`.forcedOnly` 没有强制轨时 `.off`。
    static func startupChoice(in tracks: [MPVTrack], mode: SubtitleMode) -> SubtitleStartupChoice {
        let subtitles = tracks.filter { $0.type == .sub }.sorted { $0.id < $1.id }
        switch mode {
        case .smart:
            return preferredTrackID(in: tracks).map { .track(id: $0) } ?? .leaveAlone
        case .always:
            if let id = preferredTrackID(in: tracks) { return .track(id: id) }
            guard let first = subtitles.first else { return .leaveAlone }
            return .track(id: first.id)
        case .forcedOnly:
            guard let forced = subtitles.first(where: { $0.isForced }) else { return .off }
            return .track(id: forced.id)
        case .none:
            return .off
        }
    }

    /// nil = 判不出是中文。只看 mpv 给的 `lang` 与 `title`(`MPV_INTEGRATION.md` 第 7 节)。
    static func chineseVariant(of track: MPVTrack) -> ChineseVariant? {
        let lang = normalized(track.lang)
        let title = normalized(track.title)
        let haystack = lang + " " + title

        if containsAny(haystack, traditionalMarkers) { return .traditional }
        if containsAny(haystack, simplifiedMarkers) { return .simplified }
        if containsAny(lang, chineseLanguageCodes) || containsAny(title, chineseTitleWords) {
            return .unspecified
        }
        return nil
    }

    // MARK: - 关键词表

    /// ⛔ 必须先查繁体再查简体,否则繁体会被误判成简体。
    private static let traditionalMarkers = [
        "hant", "zht", "cht", "zh-tw", "zh-hk", "zh-mo", "big5", "traditional",
        "繁體", "繁体", "正體", "正体", "繁",
    ]

    private static let simplifiedMarkers = [
        "hans", "zhs", "chs", "zh-cn", "zh-sg", "gbk", "gb2312", "simplified",
        "简体", "简體", "簡體", "簡体", "简",
    ]

    /// 子串匹配,`zh` 覆盖所有 `zh-*`
    private static let chineseLanguageCodes = ["chi", "zho", "zh", "cmn"]

    /// lang 缺失或为 `und` 时靠它
    private static let chineseTitleWords = ["中文", "汉语", "漢語", "汉字", "漢字"]

    private static func normalized(_ value: String?) -> String {
        (value ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func containsAny(_ text: String, _ markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }
}
