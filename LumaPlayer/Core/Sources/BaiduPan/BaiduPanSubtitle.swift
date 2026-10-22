import Foundation

/// 百度网盘同目录外挂字幕的配对(纯函数,无网络)。百度没有字幕接口;字幕文件就在
/// 列目录的原始结果(`filesByID`)里,按基名配对即可。
///
/// 规则刻意保守:同目录 + 字幕扩展名 + 基名等于视频基名,或视频基名后紧跟分隔符 / 语言后缀:
///
/// ```
/// 电影.mkv   + 电影.srt            ✅
/// 电影.mkv   + 电影.chs.srt        ✅(chs 作为语言后缀)
/// 电影.mkv   + 电影.zh-CN.ass      ✅
/// Show.S01E01.mkv + Show.S01E01.简体.srt ✅
/// 电影.mkv   + 另一部电影.srt      ❌(前缀不是「视频基名 + 分隔符」)
/// ```
///
/// ⛔ 不做「目录里只有一个字幕就配给它」这类猜测:混放多部片时会配错,且比没有字幕更难发现。
enum BaiduPanSubtitle {

    /// `SubtitleFormats` 的别名,⛔ 不要另写一份集合。
    static var fileExtensions: Set<String> { SubtitleFormats.fileExtensions }

    /// 只看扩展名。
    static func isSubtitle(_ file: BaiduPanFile) -> Bool {
        !file.isDirectory && SubtitleFormats.fileExtensions.contains(file.fileExtension)
    }

    /// 挑出属于这条视频的字幕,按名字自然序排好。`files` 是同一目录的列表(通常是 `filesByID.values`)。
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

    /// 菜单里显示语言标签,认不出时退回文件名。不含「外挂」二字(`MPVTrack.displayName` 已会拼上)。
    static func title(for subtitle: BaiduPanFile, video: BaiduPanFile) -> String {
        guard let suffix = languageSuffix(
            of: subtitle.name, videoBase: baseName(video.name)),
            let label = languageLabel(suffix) else {
            return subtitle.name
        }
        return label
    }

    // MARK: - 基名与语言后缀

    static func baseName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// 字幕相对视频基名的后缀。nil = 不匹配;空串 = 基名完全相同。
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

    /// 只映射确定的写法,认不出返回 nil(`cd1`、发布组名不硬翻)。
    static func languageLabel(_ suffix: String) -> String? {
        let key = suffix
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        // ⚠️ 先整串、再前缀、最后单段:先查单段的话 `zh-CN` 会撞上 `zh`,丢掉简繁区别
        if let label = table[key] { return label }
        let tokens = key.split(whereSeparator: { ".-&+".contains($0) }).map(String.init)
        // 多段后缀(`zh-cn.forced`):越长的前缀越具体
        for length in stride(from: tokens.count, through: 2, by: -1) {
            let joined = tokens.prefix(length).joined(separator: "-")
            if let label = table[joined] { return label }
        }
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
