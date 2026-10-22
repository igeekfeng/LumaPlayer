import Foundation

/// 百度条目的本地元数据合成(纯函数):只用文件名与目录结构,⛔ 不联网、不硬造简介。
/// 在线刮削是之后的另一层(`BaiduPanMetadataScraper`,`docs/TMDB_API.md`)。
///
/// 按整目录处理:封面(`poster.jpg` 等)是同目录的兄弟条目;`琅琊榜/01.mp4` 这种存法
/// 剧名在目录名上(见 `seriesFolder`)。
///
/// 图片等非音视频文件不单独成卡:`poster.jpg` 的身份就是封面。
enum BaiduPanMetadataSynthesizer {

    /// 封面此时还没有地址(要 `dlink`,由 `BaiduPanSourceProvider` 批量取)。交回整条封面文件而非 `fs_id`:
    /// 缓存 key 还要它的 `server_mtime`(`ImageDescriptor.baiduCoverKey`)。
    struct Synthesized: Sendable, Equatable {
        let item: SourceItem
        /// nil = 没有封面,UI 降级成图标卡
        let cover: BaiduPanFile?
    }

    struct ParsedName: Sendable, Equatable {
        /// 可能为空,由调用方决定是否退回文件名
        var title: String = ""
        var year: Int?
        var season: Int?
        var episode: Int?
        /// 名称里显式写的 `{tmdbid-63926}`
        var tmdbID: Int?

        var isMeaningful: Bool { !title.isEmpty || year != nil }
    }

    // MARK: - 入口

    static func synthesize(files: [BaiduPanFile], sourceID: UUID) -> [Synthesized] {
        let covers = CoverIndex(files: files)
        // 成串的 `01.mp4` / `02.mp4` 才像剧集,孤零零一个 `300.mp4` 更可能是电影(见 `seriesFolder`)
        let looksLikeEpisodeSequence = episodeLikeCount(files: files) >= 2
        var result: [Synthesized] = []
        for file in files {
            if file.isDirectory {
                result.append(Synthesized(item: folderItem(file, sourceID: sourceID), cover: nil))
            } else if file.kind.isPlayable {
                let parsed = parse(name: file.name)
                result.append(Synthesized(
                    item: mediaItem(
                        file,
                        parsed: parsed,
                        looksLikeEpisodeSequence: looksLikeEpisodeSequence,
                        sourceID: sourceID),
                    cover: covers.cover(for: file)
                ))
            }
            // 非目录、非音视频:不成卡
        }
        return result
    }

    // MARK: - 条目构造

    private static func folderItem(_ file: BaiduPanFile, sourceID: UUID) -> SourceItem {
        // 目录名可能带 `{tmdbid-…}`:取 id,展示名剥掉标签
        let explicit = extractExplicitTMDBID(in: file.name)
        let stripped = explicit?.cleaned.trimmingCharacters(in: .whitespaces)
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: file.fsID),
            // 剥完为空时退回原名
            title: (stripped?.isEmpty == false ? stripped : nil) ?? file.name,
            kind: .folder,
            overview: nil,
            year: nil,
            tmdbID: explicit?.id,
            episodeNumber: nil,
            // 季文件夹的季号,`BaiduPanSeriesLayout` 靠它判剧。用原始目录名判(标签与季标记可能同时出现)
            seasonNumber: seasonNumber(fromDirectoryName: file.name),
            episodeTitle: nil,
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: .none
        )
    }

    private static func mediaItem(
        _ file: BaiduPanFile,
        parsed: ParsedName,
        looksLikeEpisodeSequence: Bool,
        sourceID: UUID
    ) -> SourceItem {
        // `琅琊榜/01.mp4`:剧名借目录名
        let folder = seriesFolder(
            file, parsed: parsed, looksLikeEpisodeSequence: looksLikeEpisodeSequence)

        let kind: SourceItemKind
        let title: String
        let tmdbID: Int?
        let episodeNumber: Int?
        let seasonNumber: Int?
        if let folder {
            kind = .episode
            title = folder.seriesTitle
            tmdbID = folder.tmdbID ?? parsed.tmdbID
            episodeNumber = parsed.episode ?? bareEpisodeNumber(file.name)
            seasonNumber = folder.season
        } else {
            tmdbID = parsed.tmdbID
            episodeNumber = parsed.episode
            seasonNumber = parsed.season
            if parsed.episode != nil {
                kind = .episode
            } else if file.kind == .audio {
                kind = .audio
            } else {
                kind = .video
            }
            // 解析不出标题就退回文件名(去扩展名)
            title = parsed.title.isEmpty ? baseName(file.name) : parsed.title
        }
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: file.fsID),
            title: title,
            kind: kind,
            // 百度不给简介,⛔ 不从文件名硬造
            overview: nil,
            year: parsed.year,
            tmdbID: tmdbID,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            // 集名只有 TMDB 有,⛔ 不拿剧名冒充
            episodeTitle: nil,
            // 时长要另发 `filemetas`;播放时由 `authoritativeDurationSeconds` 补
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: folder != nil || parsed.isMeaningful ? .filename : .none
        )
    }

    // MARK: - 剧集文件夹结构

    struct SeriesFolder: Sendable, Equatable {
        /// 取自目录名
        let seriesTitle: String
        /// nil = 目录名与文件名都没给出
        let season: Int?
        /// 目录名里显式写的 TMDB id
        var tmdbID: Int? = nil
    }

    /// 「看起来是某一集」且文件名自己没有剧名的文件数:`01.mp4`,或 `E02.mp4` / `第01集.mp4`。
    /// `Show.S01E02.mkv` 自带剧名,不算。
    private static func episodeLikeCount(files: [BaiduPanFile]) -> Int {
        files.count { file in
            guard !file.isDirectory, file.kind.isPlayable else { return false }
            if bareEpisodeNumber(file.name) != nil { return true }
            let parsed = parse(name: file.name)
            return parsed.episode != nil && parsed.title.isEmpty
        }
    }

    /// 非 nil = 剧集文件夹:剧名取自目录名,文件名只是集号。判据按优先级:
    ///
    /// 0. 祖先目录带 `{tmdbid-N}`(标准命名库):剧名与 id 取自它,文件名的标题让位
    ///    (中英混排的发布名靠标题搜不准)。
    /// 1. 父目录是季文件夹(`琅琊榜/第13季/01.mp4`)→ 剧名取祖父目录,季号取父目录。
    /// 2. 否则父目录就是剧名(`琅琊榜/01.mp4`),季号只来自文件名,没有就是 nil(⛔ 不猜 1)。
    ///
    /// 成串闸门 `looksLikeEpisodeSequence` 只管判据 2(挡住单个 `300.mp4` 变「第 300 集」)。
    /// ⛔ 不要套到判据 1 上:特别篇季常只有一两集,会把剧名认成 `S0`(Q43)。
    private static func seriesFolder(
        _ file: BaiduPanFile,
        parsed: ParsedName,
        looksLikeEpisodeSequence: Bool
    ) -> SeriesFolder? {
        // 判据 0:文件名认得出是某一集即可
        if let annotated = annotatedAncestorDirectory(file.path),
           parsed.episode != nil || bareEpisodeNumber(file.name) != nil {
            // 文件名里的季号优先,否则看父目录
            let season = parsed.season
                ?? seasonNumber(fromDirectoryName: parentDirectoryName(file.path))
            return SeriesFolder(
                seriesTitle: annotated.title, season: season, tmdbID: annotated.tmdbID)
        }

        let isBareNumber = bareEpisodeNumber(file.name) != nil
        let isMarkedWithoutTitle = parsed.episode != nil && parsed.title.isEmpty
        guard isBareNumber || isMarkedWithoutTitle else { return nil }

        let parent = parentDirectoryName(file.path)
        guard !parent.isEmpty else { return nil }
        if let season = seasonNumber(fromDirectoryName: parent) {
            // 判据 1:不看成串闸门
            let series = grandparentDirectoryName(file.path)
            // 没有上一层目录名就不认,⛔ 不拿季文件夹名当剧名
            guard !series.isEmpty else { return nil }
            return SeriesFolder(seriesTitle: series, season: season)
        }
        // 判据 2:只有成串才当剧集
        guard looksLikeEpisodeSequence else { return nil }
        return SeriesFolder(seriesTitle: parent, season: parsed.season)
    }

    /// 最近的、目录名带 `{tmdbid-N}` 的祖先目录:给出 id 与剥掉标签的名字。嵌套时以最靠近文件的为准。
    private static func annotatedAncestorDirectory(_ path: String) -> (title: String, tmdbID: Int)? {
        var current = path
        while true {
            current = (current as NSString).deletingLastPathComponent
            let name = (current as NSString).lastPathComponent
            if name.isEmpty || name == "/" { return nil }
            guard let explicit = extractExplicitTMDBID(in: name) else { continue }
            let title = explicit.cleaned.trimmingCharacters(in: .whitespaces)
            // 目录名只有标签 → 给不出剧名,不认
            guard !title.isEmpty else { return nil }
            return (title, explicit.id)
        }
    }

    /// 整个目录名是季标记时给出季号:`第13季`、`Season 13` / `season13` / `Season.13`、`S13`。
    ///
    /// 0 是合法值(特别篇,`docs/TMDB_API.md` §7);⛔ 调用方要用 nil 判断「没认出」,不能用「非 0」(Q43)。
    /// `琅琊榜 第13季`(剧名与季号挤一起)与中文数字 `第十三季` 不认,不猜。
    static func seasonNumber(fromDirectoryName name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        func number(_ text: Substring) -> Int? {
            guard let value = Int(text), value >= 0 else { return nil }
            return value
        }
        let normalized = trimmed
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if let match = normalized.wholeMatch(of: /第(\d{1,2})季/) {
            return number(match.1)
        }
        if let match = normalized.wholeMatch(of: /[Ss]eason\s*(\d{1,2})/) {
            return number(match.1)
        }
        if let match = trimmed.wholeMatch(of: /[Ss](\d{1,2})/) {
            return number(match.1)
        }
        return nil
    }

    /// 文件名整个就是集号:`01.mp4`,或集号紧跟发布标记 `47-4K.高码率.mkv` → 47。
    /// 只认 1–3 位(4 位是年份形状)。后一种与 `300.1080p.BluRay.mkv` 分不出,
    /// 所以调用方只在同目录成串时才信(`looksLikeEpisodeSequence`)。
    static func bareEpisodeNumber(_ name: String) -> Int? {
        let base = baseName(name).trimmingCharacters(in: .whitespaces)
        if (1...3).contains(base.count), base.allSatisfy({ $0.isASCII && $0.isNumber }),
           let number = Int(base), number > 0 {
            return number
        }
        // 集号 + 发布标记
        let tokens = tokenize(base)
        guard tokens.count >= 2, let first = tokens.first,
              (1...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(first), number > 0,
              isReleaseTag(tokens[1]) else {
            return nil
        }
        return number
    }

    /// 拿不到时为 `""`
    private static func parentDirectoryName(_ path: String) -> String {
        directoryName(atLevel: 1, of: path)
    }

    /// 拿不到时为 `""`
    private static func grandparentDirectoryName(_ path: String) -> String {
        directoryName(atLevel: 2, of: path)
    }

    /// `level = 1` 是父目录
    private static func directoryName(atLevel level: Int, of path: String) -> String {
        var current = path
        for _ in 0..<level {
            current = (current as NSString).deletingLastPathComponent
        }
        let name = (current as NSString).lastPathComponent
        return name == "/" ? "" : name
    }

    // MARK: - 文件名解析

    /// 抠出显式 TMDB id 并返回剥掉标签的名称。认 `{tmdbid-N}` / `[…]` / `(…)` / 裸写,
    /// 键名 `tmdbid` / `tmdb`(不分大小写),分隔符 `-` / `=`。
    /// 标签不说明是电影还是剧(两个 id 空间),由刮削层按上下文决定查哪个端点。
    static func extractExplicitTMDBID(in name: String) -> (id: Int, cleaned: String)? {
        // 带括号的先试,连括号一起剥
        if let match = name.firstMatch(of: /[\[{(]\s*(?i:tmdbid|tmdb)\s*[-=]\s*(\d{1,9})\s*[\])}]/),
           let id = Int(match.1) {
            return (id, removing(match.range, from: name))
        }
        if let match = name.firstMatch(of: /(?i:tmdbid|tmdb)\s*[-=]\s*(\d{1,9})/),
           let id = Int(match.1) {
            return (id, removing(match.range, from: name))
        }
        return nil
    }

    /// 删掉区间并把多余空白收成一个空格
    private static func removing(_ range: Range<String.Index>, from name: String) -> String {
        var text = name
        text.removeSubrange(range)
        return text
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// 规则(顺序即优先级):
    /// 0. 显式 `{tmdbid-N}`:抠出并剥掉,不参与标题;
    /// 1. 季集 `S01E02` / `E02` / `第01集`;
    /// 2. 年份:`1900...2099` 且后面紧跟发布标记或到结尾(片名里的 `1917` 后面不是发布标记,不会误判);
    /// 3. 发布标记:命中即截断。
    static func parse(name: String) -> ParsedName {
        let base = (name as NSString).deletingPathExtension
        let explicit = extractExplicitTMDBID(in: base)
        let cleaned = explicit?.cleaned ?? base
        let tokens = tokenize(cleaned)

        var parsed = ParsedName()
        parsed.tmdbID = explicit?.id
        var titleTokens: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if let seasonEpisode = seasonEpisode(in: token) {
                parsed.season = seasonEpisode.season
                parsed.episode = seasonEpisode.episode
                index += 1
                continue
            }
            if let year = yearToken(tokens: tokens, at: index) {
                parsed.year = year
                break   // 年份之后是发布信息,标题到此为止
            }
            if isReleaseTag(token) { break }
            titleTokens.append(token)
            index += 1
        }

        parsed.title = titleTokens.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return parsed
    }

    /// `.` `_` `-` 空白与括号都当分隔符(`47-4K.高码率` → `["47", "4K", "高码率"]`)
    private static func tokenize(_ base: String) -> [String] {
        base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })
            .map(String.init)
    }

    /// 见 `parse` 规则 2
    private static func yearToken(tokens: [String], at index: Int) -> Int? {
        let token = tokens[index]
        guard token.count == 4, let year = Int(token), (1900...2099).contains(year) else {
            return nil
        }
        guard index + 1 < tokens.count else { return year }
        return isReleaseTag(tokens[index + 1]) ? year : nil
    }

    private static func seasonEpisode(in token: String) -> (season: Int?, episode: Int)? {
        if let match = token.wholeMatch(of: /[Ss](\d{1,2})[Ee](\d{1,3})/),
           let season = Int(match.1), let episode = Int(match.2) {
            return (season, episode)
        }
        // 下面两种不带季号,季返回 nil。⛔ 不用 0 当哨兵:0 是特别篇(`docs/TMDB_API.md` §7)
        if let match = token.wholeMatch(of: /[Ee][Pp]?(\d{1,3})/), token.count <= 4 {
            return (nil, Int(match.1) ?? 0)
        }
        if let match = token.wholeMatch(of: /第(\d{1,3})[集话話]/) {
            return (nil, Int(match.1) ?? 0)
        }
        return nil
    }

    /// 白名单:不认识的词算进标题,宁可标题长一点也不吃掉真标题
    static let releaseTags: Set<String> = [
        // 分辨率
        "1080p", "720p", "480p", "2160p", "4k", "uhd", "hd", "sd", "fhd",
        // 片源
        "web", "webdl", "webrip", "bluray", "bdrip", "brrip", "hdtv", "dvdrip",
        "dvd", "hdrip", "remux", "tvrip", "hdtc",
        // 编码
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "10bit", "8bit",
        // 音轨
        "aac", "ac3", "eac3", "dts", "dtshd", "truehd", "flac", "mp3", "ddp", "atmos",
        // 画质增强
        "hdr", "hdr10", "dv", "dovi", "sdr", "imax", "3d",
        // 版本
        "proper", "repack", "extended", "uncut", "remastered", "directors", "unrated",
        // 常见的组名后缀
        "yts", "rarbg", "ntb", "fgt", "cmct", "chd", "wiki",
    ]

    /// 常连写成一个 token(`国语中字`),所以按包含判定
    private static let chineseReleaseMarkers = [
        "国语", "粤语", "英语", "中字", "简中", "繁中", "双语", "简繁",
        "字幕", "内嵌", "外挂", "高清", "蓝光", "修复版", "高码率", "高碼率",
    ]

    static func isReleaseTag(_ token: String) -> Bool {
        let lower = token.lowercased()
        if releaseTags.contains(lower) { return true }
        return chineseReleaseMarkers.contains { lower.contains($0) }
    }

    /// 去扩展名,保留原样
    static func baseName(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    // MARK: - 封面索引

    /// 同目录封面:同名图 > `poster` > `folder` > `cover`,不分大小写
    private struct CoverIndex {
        private static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp"]
        private static let directoryNames = ["poster", "folder", "cover"]

        private var byBaseName: [String: BaiduPanFile] = [:]
        private var byDirectoryName: [String: BaiduPanFile] = [:]

        init(files: [BaiduPanFile]) {
            for file in files where !file.isDirectory {
                guard Self.extensions.contains(file.fileExtension) else { continue }
                let base = BaiduPanMetadataSynthesizer.baseName(file.name).lowercased()
                byBaseName[base] = file
                if Self.directoryNames.contains(base) {
                    byDirectoryName[base] = file
                }
            }
        }

        func cover(for file: BaiduPanFile) -> BaiduPanFile? {
            let base = BaiduPanMetadataSynthesizer.baseName(file.name).lowercased()
            if let sameName = byBaseName[base] { return sameName }
            for name in Self.directoryNames {
                if let directoryCover = byDirectoryName[name] { return directoryCover }
            }
            return nil
        }
    }
}
