import Foundation

/// 起播时的字幕默认偏好:简体中文 → 繁体中文 → 保持 mpv 的 `sid=auto`。
///
/// ## 为什么自己判,不交给 mpv 的 `slang`
///
/// `slang` 只按语言码匹配(`chi` / `zho` / `zh` 一视同仁),**区分不了简体与繁体**;
/// 而中文资源里简繁常常都标 `chi`,真正区分依据在压制组写进 `title` 的
/// 「简体」「繁體」「Chinese (Traditional)」。另外 `MPVPlayer` 设了 `config=no`,
/// 用户自己 mpv.conf 里的 `slang` 也不生效 —— 偏好只能落在客户端。
///
/// ## 判定结果的四档
///
/// 1. 明确简体(`zh-Hans` / `chs` / 「简体」/ `Simplified` …)
/// 2. 明确繁体(`zh-Hant` / `cht` / 「繁體」/ `Traditional` …)
/// 3. 只标了「中文」没标变体(`chi` / `zho` + 无变体线索)—— 它是中文字幕,
///    但简繁未知,排在明确繁体之后,免得把一条明确的繁体挤掉
/// 4. 判不出中文 → 返回 nil
///
/// ⛔ 判不出来一律返回 nil(**不动**,保持 mpv 选的 default 轨),不猜:
/// 宁可让 mpv 自己选,也不能把一条英文字幕当成中文选上。
///
/// 起播时的字幕模式(设置页「播放」页可选)。
///
/// 与 Emby 服务端 `UserConfiguration.SubtitleMode` 的几档同名,但**互不相干**:
/// LumaPlayer 不读写该配置(未在 `API_CONTRACT.md` 核实),这里只是本地起播偏好,
/// 全部服务器共用一份。
enum SubtitleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }

    /// 中文优先(默认):简中 → 繁中 → 未标变体的中文 → 不动 mpv 默认
    case smart
    /// 总是开:没有中文字幕时开第一条字幕轨
    case always
    /// 只开强制字幕(`track-list/N/forced`);没有强制轨就关字幕
    case forcedOnly
    /// 起播不开字幕(播放中仍可手动开)
    case none

    /// 设置页显示名
    var label: String {
        switch self {
        case .smart: "中文优先"
        case .always: "总是开字幕"
        case .forcedOnly: "只开强制字幕"
        case .none: "起播不开字幕"
        }
    }

    /// 设置页 footer 里的一句解释
    var detail: String {
        switch self {
        case .smart: "有简体中文选简体,没有再找繁体;都没有就交给 mpv 的默认轨。"
        case .always: "优先中文字幕,一条中文都没有时打开第一条字幕轨。"
        case .forcedOnly: "只显示标记为「强制」的字幕(通常是外语对白的那几句);没有强制轨就关掉字幕。"
        case .none: "每次起播都关闭字幕,想看时自己在控制栏的字幕菜单里开。"
        }
    }
}

/// 起播时对字幕轨的处理结果。
enum SubtitleStartupChoice: Equatable, Sendable {
    /// 不要动:保持 mpv 自己选的轨
    case leaveAlone
    /// 关掉字幕(`sid = no`)
    case off
    /// 选这条轨
    case track(id: Int)
}

/// 纯函数,无状态,可脱离 mpv 与网络测试。
enum SubtitlePreference {

    /// 默认该选哪条字幕轨;nil = 保持 mpv 的 `sid=auto`,不要动。
    /// 同一档内取 `id` 最小的那条(与 `StreamIndexMapper` 一样按轨道顺序)。
    static func preferredTrackID(in tracks: [MPVTrack]) -> Int? {
        var traditional: Int?
        var unspecifiedChinese: Int?

        for track in tracks.filter({ $0.type == .sub }).sorted(by: { $0.id < $1.id }) {
            switch chineseVariant(of: track) {
            case .simplified:
                return track.id          // 已按 id 升序,第一个简体就是要的
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

    /// 一条轨与中文的关系;`nil` = 判不出是中文。
    enum ChineseVariant: Equatable {
        case simplified
        case traditional
        /// 是中文,但简繁未知
        case unspecified
    }

    /// 起播时该对字幕做什么:在「中文优先」的基础上按模式放宽 / 收紧。
    ///
    /// `.smart` 判不出中文时返回 `.leaveAlone`(⛔ 不猜),`.always` 才退到第一条轨;
    /// `.forcedOnly` 找不到强制轨时返回 `.off` —— 用户只要强制字幕,那就该关着。
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

    /// 判定依据只有 mpv 给的 `lang` 与 `title`(`MPV_INTEGRATION.md` 第 7 节),
    /// ⛔ 没有第三个来源 —— 不读文件名、不读容器元数据。
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

    /// 繁体线索。⚠️ 先查繁体再查简体:`zh-Hant` 里同时含 `zh`,
    /// 反过来会把繁体误判成简体。
    private static let traditionalMarkers = [
        "hant", "zht", "cht", "zh-tw", "zh-hk", "zh-mo", "big5", "traditional",
        "繁體", "繁体", "正體", "正体", "繁",
    ]

    private static let simplifiedMarkers = [
        "hans", "zhs", "chs", "zh-cn", "zh-sg", "gbk", "gb2312", "simplified",
        "简体", "简體", "簡體", "簡体", "简",
    ]

    /// ISO 639 / BCP 47 里「中文」的语言码。`zh` 是 `zh-*` 的公共前缀,
    /// 因此 `chi` / `zho` / `zh-hans` 都会命中;变体判定已在前面完成。
    private static let chineseLanguageCodes = ["chi", "zho", "zh", "cmn"]

    /// title 里的中文词(简繁都算),用于 lang 缺失或写的是 `und` 的情况。
    private static let chineseTitleWords = ["中文", "汉语", "漢語", "汉字", "漢字"]

    private static func normalized(_ value: String?) -> String {
        (value ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func containsAny(_ text: String, _ markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }
}
