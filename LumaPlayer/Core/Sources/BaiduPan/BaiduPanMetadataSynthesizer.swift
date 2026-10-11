import Foundation

/// 百度网盘 → 条目的**本地元数据合成**(纯函数,无网络)。
///
/// ## 为什么必须有它
///
/// 百度只给文件名。要让百度来源看起来像 Emby(标题、年份、封面),
/// 就必须在客户端把**网盘里已有的信息**合成出来 ——
/// ⛔ 不联网刮削,⛔ 不用文件名硬造简介(`docs/SOURCE_ABSTRACTION_PLAN.md` §6.3)。
///
/// ## 为什么要整目录一起处理
///
/// `poster.jpg` / `folder.jpg` 这类封面**不在这条视频自己的元数据里** ——
/// 它们是同目录的**兄弟条目**。只看单个文件根本配不出封面。
///
/// ## 一条明确的取舍
///
/// **图片与其它非媒体文件不单独成卡。** 本 App 是播放器不是图库,
/// 而 `poster.jpg` 在这里的身份就是封面。⛔ 不把它们做成「不可播」的卡片
/// 混进片单 —— 那会让一个 20 部片的目录变成 40 张卡。
enum BaiduPanMetadataSynthesizer {

    /// 合成结果:条目 + 「它的封面是同目录哪个文件」。
    ///
    /// ⚠️ 封面此时**还没有地址** —— 百度要先拿 `dlink` 才有 URL,而合成器不认识网络
    /// (`docs/BAIDU_PAN_API.md` §2.2)。那一步由 `BaiduPanSourceProvider` **批量**做。
    /// 这里交回**整条封面文件**而不只是 `fs_id`:Provider 还需要它的 `server_mtime`
    /// 去拼缓存 key 的版本段(`ImageDescriptor.baiduCoverKey`)。
    struct Synthesized: Sendable, Equatable {
        let item: SourceItem
        /// 配到的封面文件(nil = 没有封面,UI 降级成图标卡)
        let cover: BaiduPanFile?
    }

    /// 从文件名解析出来的信息。
    struct ParsedName: Sendable, Equatable {
        /// 解析出来的标题。**可能为空** —— 由调用方决定是否退回文件名
        var title: String = ""
        var year: Int?
        var season: Int?
        var episode: Int?

        /// 标题或年份至少解析出一个
        var isMeaningful: Bool { !title.isEmpty || year != nil }
    }

    // MARK: - 入口

    /// 把一个目录的原始条目合成为卡片 + 封面引用。
    static func synthesize(files: [BaiduPanFile], sourceID: UUID) -> [Synthesized] {
        let covers = CoverIndex(files: files)
        var result: [Synthesized] = []
        for file in files {
            if file.isDirectory {
                result.append(Synthesized(item: folderItem(file, sourceID: sourceID), cover: nil))
            } else if file.kind.isPlayable {
                let parsed = parse(name: file.name)
                result.append(Synthesized(
                    item: mediaItem(file, parsed: parsed, sourceID: sourceID),
                    cover: covers.cover(for: file)
                ))
            }
            // 非目录、非音视频:不成卡(见类型注释的取舍)
        }
        return result
    }

    // MARK: - 条目构造

    private static func folderItem(_ file: BaiduPanFile, sourceID: UUID) -> SourceItem {
        SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: file.fsID),
            title: file.name,
            kind: .folder,
            overview: nil,
            year: nil,
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: .none
        )
    }

    private static func mediaItem(
        _ file: BaiduPanFile,
        parsed: ParsedName,
        sourceID: UUID
    ) -> SourceItem {
        let kind: SourceItemKind
        if parsed.episode != nil {
            kind = .episode
        } else if file.kind == .audio {
            kind = .audio
        } else {
            kind = .video
        }
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: file.fsID),
            // 解析不出标题就退回文件名(去扩展名)—— ⛔ 不留空标题
            title: parsed.title.isEmpty ? baseName(file.name) : parsed.title,
            kind: kind,
            // 百度不给简介。⛔ 不从文件名硬造 —— 那是最典型的假数据
            overview: nil,
            year: parsed.year,
            // 时长要另发 `filemetas` 才有;播放时会由 `authoritativeDurationSeconds` 补上
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: parsed.isMeaningful ? .filename : .none
        )
    }

    // MARK: - 文件名解析

    /// 从文件名解析标题 / 年份 / 季集。
    ///
    /// 规则(顺序即优先级):
    /// 1. **季集**:`S01E02` / `E02` / `第01集` —— 命中就把条目判成剧集;
    /// 2. **年份**:4 位数且在 `1900...2099`,**且后面紧跟发布标记或到此为止**。
    ///    这条约束是关键:片名里也可能有 4 位数字(`1917`),
    ///    但它后面跟的是另一个数字而不是 `1080p`,所以不会被误判成上映年;
    /// 3. **发布标记**:命中即截断,后面的都是编码 / 音轨 / 语言信息。
    static func parse(name: String) -> ParsedName {
        let base = (name as NSString).deletingPathExtension
        // 归一化分隔符:发布组习惯用 `.` 与 `_`(`Some.Movie.2019.1080p.mkv`)
        let normalized = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            // 括号只包着年份(`Some.Movie.(2019)`),去掉不影响别的
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
        let tokens = normalized
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })
            .map(String.init)

        var parsed = ParsedName()
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

    /// 是不是一个「上映年」形状的 token(见 `parse` 第 2 条规则)
    private static func yearToken(tokens: [String], at index: Int) -> Int? {
        let token = tokens[index]
        guard token.count == 4, let year = Int(token), (1900...2099).contains(year) else {
            return nil
        }
        // 后面必须紧跟发布标记或到此为止
        guard index + 1 < tokens.count else { return year }
        return isReleaseTag(tokens[index + 1]) ? year : nil
    }

    private static func seasonEpisode(in token: String) -> (season: Int, episode: Int)? {
        if let match = token.wholeMatch(of: /[Ss](\d{1,2})[Ee](\d{1,3})/) {
            return (Int(match.1) ?? 0, Int(match.2) ?? 0)
        }
        if let match = token.wholeMatch(of: /[Ee][Pp]?(\d{1,3})/), token.count <= 4 {
            return (0, Int(match.1) ?? 0)
        }
        if let match = token.wholeMatch(of: /第(\d{1,3})[集话話]/) {
            return (0, Int(match.1) ?? 0)
        }
        return nil
    }

    /// 发布标记词。命中即认为「这之后不是标题」。
    ///
    /// ⚠️ 表是**白名单**而不是黑名单:不认识的词会被当成标题的一部分,
    /// 结果是标题长一点(可接受),而不是把真标题吃掉(不可接受)。
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

    /// 中文标记常常连写成一个 token(`国语中字`),所以用「包含」判定
    private static let chineseReleaseMarkers = [
        "国语", "粤语", "英语", "中字", "简中", "繁中", "双语", "简繁",
        "字幕", "内嵌", "外挂", "高清", "蓝光", "修复版",
    ]

    static func isReleaseTag(_ token: String) -> Bool {
        let lower = token.lowercased()
        if releaseTags.contains(lower) { return true }
        return chineseReleaseMarkers.contains { lower.contains($0) }
    }

    /// 去扩展名(保留原始大小写与空格,给「退回文件名」用)
    static func baseName(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    // MARK: - 封面索引

    /// 同目录里的封面候选。
    ///
    /// 优先级:同名图(`movie.jpg`) > `poster.jpg` > `folder.jpg` > `cover.jpg`。
    /// 大小写不敏感 —— 网盘里 `Poster.JPG` 也得认。
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
