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
