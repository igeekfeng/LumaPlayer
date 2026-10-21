import Foundation

/// 百度网盘目录里的**外挂字幕**匹配(纯函数,无网络)。
///
/// ## 为什么需要它
///
/// 网盘里的片源普遍把字幕单独放成 `.srt` / `.ass`(`电影.mkv` + `电影.chs.srt`)。
/// 这些文件在播放器看来只是同目录的另一个文件 —— 不主动挂上去,用户就只能看到
/// 内嵌字幕(很多片源压根没有)。百度没有任何「字幕」接口,所以这件事只能在
/// 客户端做:列目录时它们本来就在列表里(合成器把非媒体文件滤掉了,但**原始文件**
/// 还在 `filesByID` 里),按基名配对即可,⛔ 不需要额外的搜索请求。
///
/// ## 配对规则(刻意保守)
///
/// 只认「**同目录 + 字幕扩展名 + 基名等于视频基名,或视频基名后面紧跟分隔符 / 语言后缀**」:
///
/// ```
/// 电影.mkv   + 电影.srt            ✅
/// 电影.mkv   + 电影.chs.srt        ✅(chs 作为语言后缀)
/// 电影.mkv   + 电影.zh-CN.ass      ✅
/// Show.S01E01.mkv + Show.S01E01.简体.srt ✅
/// 电影.mkv   + 另一部电影.srt      ❌(前缀不是「视频基名 + 分隔符」)
/// ```
///
/// ⛔ 不做「目录里只有一个字幕就配给它」这类猜测 —— 一个目录里混着多部片时
/// 会把字幕配错,而配错的字幕比没有字幕更难发现。
enum BaiduPanSubtitle {

    /// 认得的字幕扩展名。
    ///
    /// `sub` 是 MicroDVD(老片常见),`vtt` 给 Web 来源;`smi` 不在内 ——
    /// libmpv 对它支持不稳,列进来只会多一条加载失败的轨。
    static let fileExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    /// 这条文件是不是字幕(只看扩展名,不看内容)。
    static func isSubtitle(_ file: BaiduPanFile) -> Bool {
        !file.isDirectory && fileExtensions.contains(file.fileExtension)
    }

    /// 从一批同目录文件里挑出属于这条视频的字幕,按名字自然序排好。
    ///
    /// - Parameters:
    ///   - video: 要播的那条文件
    ///   - files: **同一个目录**的文件列表(通常是 `filesByID.values`)
    static func files(for video: BaiduPanFile, in files: [BaiduPanFile]) -> [BaiduPanFile] {
        let videoBase = baseName(video.name)
        guard !videoBase.isEmpty else { return [] }
        let directory = BaiduPanPath.directory(ofFilePath: video.path)
        return files
            .filter { candidate in
                guard isSubtitle(candidate),
                      candidate.fsID != video.fsID,
                      BaiduPanPath.directory(ofFilePath: candidate.path) == directory
                else { return false }
                return languageSuffix(of: candidate.name, videoBase: videoBase) != nil
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 字幕在菜单里显示的名字:语言标签;认不出语言时退回文件名。
    ///
    /// 返回值**不含**「外挂」二字 —— mpv 的 `track-list` 自己会带 `external` 标记,
    /// 菜单副标题已经会拼上去(`MPVTrack.displayName`),这里再加一次就重复了。
    static func title(for subtitle: BaiduPanFile, video: BaiduPanFile) -> String {
        guard let suffix = languageSuffix(
            of: subtitle.name, videoBase: baseName(video.name)),
            let label = languageLabel(suffix) else {
            return subtitle.name
        }
        return label
    }

    // MARK: - 基名与语言后缀

    /// 去掉扩展名的文件名。
    static func baseName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// 字幕相对视频基名的**后缀**;不匹配返回 nil。
    ///
    /// 返回空串表示「基名完全相同」(没有任何语言标记)。
    static func languageSuffix(of subtitleName: String, videoBase: String) -> String? {
        let subtitleBase = baseName(subtitleName)
        let videoLower = videoBase.lowercased()
        let subtitleLower = subtitleBase.lowercased()
        guard subtitleLower.hasPrefix(videoLower) else { return nil }
        let remainder = String(subtitleBase.dropFirst(videoBase.count))
        guard !remainder.isEmpty else { return "" }
        // 紧跟分隔符才算同一条视频的后缀:`电影2.srt` 不该配给 `电影.mkv`
        guard let first = remainder.first,
              ". _-—[]()".contains(first) else { return nil }
        return remainder.trimmingCharacters(in: CharacterSet(charactersIn: ". _-—[]()"))
    }

    /// 语言后缀 → 菜单里的中文标签。认不出来返回 nil(调用方退回文件名)。
    ///
    /// ⚠️ 只映射**确定**的写法(`chs` / `zh-cn` / `简体` …)。猜不出来的
    /// (`cd1`、发布组名)不硬翻 —— 那种后缀本来也不是语言。
    static func languageLabel(_ suffix: String) -> String? {
        let key = suffix
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        // ⚠️ **先整串、再前缀、最后单段**:`zh-CN` 若先按单段查会撞上 `zh` →「中文」,
        // 简体 / 繁体的区别就丢了(`zh-CN` / `zh-TW` 是同一个词根的两种写法)。
        if let label = table[key] { return label }
        let tokens = key.split(whereSeparator: { ".-&+".contains($0) }).map(String.init)
        // 多段后缀(`zh-cn.forced` / `chs.eng`):按「越长的前缀越具体」逐级试
        for length in stride(from: tokens.count, through: 2, by: -1) {
            let joined = tokens.prefix(length).joined(separator: "-")
            if let label = table[joined] { return label }
        }
        // 再退到单段(`chs` / `forced` / `sdh`)
        for token in tokens {
            if let label = table[token] { return label }
        }
        return nil
    }

    private static let table: [String: String] = [
        "zh": "中文", "chi": "中文", "zho": "中文", "chs": "简体中文",
        "zh-cn": "简体中文", "zh-hans": "简体中文", "sc": "简体中文",
        "gb": "简体中文", "简体": "简体中文", "简中": "简体中文", "简": "简体中文",
        "cht": "繁体中文", "zh-tw": "繁体中文", "zh-hk": "繁体中文",
        "zh-hant": "繁体中文", "tc": "繁体中文", "big5": "繁体中文",
        "繁体": "繁体中文", "繁中": "繁体中文", "繁": "繁体中文",
        "en": "英文", "eng": "英文", "english": "英文", "英文": "英文",
        "ja": "日文", "jpn": "日文", "jp": "日文", "日文": "日文", "日语": "日文",
        "ko": "韩文", "kor": "韩文", "kr": "韩文", "韩文": "韩文", "韩语": "韩文",
        "forced": "强制", "force": "强制", "sdh": "听障", "cc": "听障",
        "bilingual": "双语", "双语": "双语", "中英": "中英双语",
    ]
}
