import Foundation

/// 百度网盘 → 条目的**本地元数据合成**(纯函数,无网络)。
///
/// ## 为什么必须有它
///
/// 百度只给文件名。要让百度来源看起来像 Emby(标题、年份、封面),
/// 就必须在客户端把**网盘里已有的信息**合成出来 ——
/// ⛔ 这个合成器**自己不认识网络**:它不联网、不查 TMDB,⛔ 也不用文件名硬造简介。
///
/// (在线刮削是**另一层**,接在它之后:文件名解析出的标题 / 年份 → TMDB 查询 →
/// 补封面 / 简介。见 `docs/TMDB_API.md` 与 `docs/SOURCE_ABSTRACTION_PLAN.md` §6.3。)
///
/// ## 为什么要整目录一起处理
///
/// `poster.jpg` / `folder.jpg` 这类封面**不在这条视频自己的元数据里** ——
/// 它们是同目录的**兄弟条目**。只看单个文件根本配不出封面。
///
/// 同理还有**剧集文件夹结构**:`琅琊榜/01.mp4` 这种「目录名是剧名、文件名只是集号」
/// 的存法,单个文件名也给不出剧名 —— 得整目录一起看(见 `seriesFolder`)。
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
        /// 名称里显式写出的 TMDB id(`{tmdbid-63926}`)。见 `extractExplicitTMDBID`
        var tmdbID: Int?

        /// 标题或年份至少解析出一个
        var isMeaningful: Bool { !title.isEmpty || year != nil }
    }

    // MARK: - 入口

    /// 把一个目录的原始条目合成为卡片 + 封面引用。
    static func synthesize(files: [BaiduPanFile], sourceID: UUID) -> [Synthesized] {
        let covers = CoverIndex(files: files)
        // 「这一层装的是不是一部剧」要在**整目录**上判,单个文件名看不出来:
        // 目录里成串的 `01.mp4` / `02.mp4` 才是剧集的特征,孤零零一个 `300.mp4`
        // 更可能是一部叫《300》的电影(见 `seriesFolder`)。
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
            // 非目录、非音视频:不成卡(见类型注释的取舍)
        }
        return result
    }

    // MARK: - 条目构造

    private static func folderItem(_ file: BaiduPanFile, sourceID: UUID) -> SourceItem {
        // 目录名里可能带显式 TMDB id(`一拳超人 (2015) {tmdbid-63926}`):
        // 取 id 展示名剥掉标签 —— `{tmdbid-…}` 是元数据,不是目录名该显示的东西。
        let explicit = extractExplicitTMDBID(in: file.name)
        let stripped = explicit?.cleaned.trimmingCharacters(in: .whitespaces)
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: file.fsID),
            // 剥完标签若是空的(目录名就只是那个标签)→ 退回原名,⛔ 不留空标题
            title: (stripped?.isEmpty == false ? stripped : nil) ?? file.name,
            kind: .folder,
            overview: nil,
            year: nil,
            tmdbID: explicit?.id,
            episodeNumber: nil,
            seasonNumber: nil,
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
        // 剧集文件夹结构(`琅琊榜/01.mp4`):文件名自己给不出剧名,借目录名
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
            // 剧集文件夹结构下 id 取自目录名(见 `seriesFolder`);文件名自己带标签时也认
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
            // 解析不出标题就退回文件名(去扩展名)—— ⛔ 不留空标题
            title = parsed.title.isEmpty ? baseName(file.name) : parsed.title
        }
        return SourceItem(
            ref: SourceItemRef(sourceID: sourceID, fsID: file.fsID),
            title: title,
            kind: kind,
            // 百度不给简介。⛔ 不从文件名硬造 —— 那是最典型的假数据
            overview: nil,
            year: parsed.year,
            tmdbID: tmdbID,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            // 集名只有 TMDB 的分集数据里有 —— 合成器给不出,⛔ 不拿剧名冒充
            episodeTitle: nil,
            // 时长要另发 `filemetas` 才有;播放时会由 `authoritativeDurationSeconds` 补上
            durationSeconds: nil,
            poster: nil,
            metadataOrigin: folder != nil || parsed.isMeaningful ? .filename : .none
        )
    }

    // MARK: - 剧集文件夹结构

    /// 剧集文件夹结构解析结果。
    struct SeriesFolder: Sendable, Equatable {
        /// 剧名(取自目录名)
        let seriesTitle: String
        /// 季号。`nil` = 目录名与文件名都没给出季号
        let season: Int?
        /// 目录名里显式写出的 TMDB id(`一拳超人 (2015) {tmdbid-63926}`)。`nil` = 没有
        var tmdbID: Int? = nil
    }

    /// 这一层里「看起来是某一集」的文件有几个。
    ///
    /// 判据只有两种,都要求文件名**自己认不出剧名**:
    /// - 整个文件名就是集号(`01.mp4` / `12.mp4`);
    /// - 文件名带了明确的集标记但没带标题(`E02.mp4` / `第01集.mp4`)。
    ///
    /// ⚠️ 带标题的不算(`Show.S01E02.mkv` 自己就有剧名,不需要借目录名)。
    private static func episodeLikeCount(files: [BaiduPanFile]) -> Int {
        files.count { file in
            guard !file.isDirectory, file.kind.isPlayable else { return false }
            if bareEpisodeNumber(file.name) != nil { return true }
            let parsed = parse(name: file.name)
            return parsed.episode != nil && parsed.title.isEmpty
        }
    }

    /// 该不该把目录名当成剧名,以及季号是多少。
    ///
    /// 返回非 nil 表示「这是个剧集文件夹」:剧名取自目录名,文件名只是集号。
    ///
    /// ## 三条判据(按优先级)
    ///
    /// 0. **祖先目录带显式 TMDB id**(`一拳超人 (2015) {tmdbid-63926}/Season 1/…`):
    ///    带这个标签的目录就是这部剧的根 —— 剧名与 id 都取自它,文件名自己的标题让位。
    ///    这条是为**标准命名库**加的:`一拳超人.ONE PUNCH MAN.2015.S01E12…` 这种中英混排标题
    ///    靠标题根本搜不准,而目录名已经给了权威 id。
    /// 1. 父目录是**季文件夹**(`琅琊榜/第13季/01.mp4`)→ 剧名取**祖父**目录、季号取父目录名;
    /// 2. 否则父目录就是剧名(`琅琊榜/01.mp4`)→ 季号只能来自文件名(`Show.S02E07`);
    ///    文件名也没写季号时为 `nil`,⛔ 不在这里猜 1(`BaiduPanMetadataScraper` 决定怎么办)。
    ///
    /// ⚠️ **成串闸门(`looksLikeEpisodeSequence`)只管判据 2**。
    /// 它存在是为了挡住平铺存法里的误判 —— 孤零零一个 `300.mp4` 不能变成
    /// 「《Movies》第 300 集」。但**判据 1 不需要它**:父目录整个就是一个季标记
    /// (`S0` / `Season 2` / `第13季`),它自己就说明「这一层装的是某一季」,
    /// 与同层有几集无关。⛔ 若把闸门也套在判据 1 上,特别篇季(常常只有一两集)
    /// 就会漏判,进而**把剧名认成那个季文件夹名**(Q43:`一拳超人/S0/01.mp4` → 剧名变 `S0`)。
    /// 判据 0 同样不受闸门约束:显式 id 本身就是「这是哪部剧」的权威答案。
    private static func seriesFolder(
        _ file: BaiduPanFile,
        parsed: ParsedName,
        looksLikeEpisodeSequence: Bool
    ) -> SeriesFolder? {
        // 判据 0:祖先目录带显式 id。只要文件名认得出是**某一集**,就借它当剧名 + id。
        if let annotated = annotatedAncestorDirectory(file.path),
           parsed.episode != nil || bareEpisodeNumber(file.name) != nil {
            // 季号:文件名里的优先(`S01E12`);否则看父目录是不是季文件夹(`Season 1`)
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
            // 判据 1:**不看** `looksLikeEpisodeSequence`(理由见类型注释)。
            let series = grandparentDirectoryName(file.path)
            // 季文件夹的上一层必须有个目录名才是剧名;拿不到就**不认**这一层,
            // ⛔ 不拿季文件夹名(`第13季` / `S0`)当剧名 —— 那样 TMDB 搜不到东西,
            // 也不会误配成别的剧。
            guard !series.isEmpty else { return nil }
            return SeriesFolder(seriesTitle: series, season: season)
        }
        // 判据 2:平铺存法,没有季文件夹帮衬 → 只有成串的集号才敢当剧集。
        // 季号只能来自文件名(`琅琊榜/Show.S02E07.mkv`),没写就是 `nil`(⛔ 不猜 1)。
        guard looksLikeEpisodeSequence else { return nil }
        return SeriesFolder(seriesTitle: parent, season: parsed.season)
    }

    /// 路径上最近的、目录名带显式 `{tmdbid-N}` 的**祖先目录**。
    ///
    /// 标准命名库里带这个标签的目录就是这部剧 / 这部电影的根,
    /// 所以它同时给出「权威 id」与「剥掉标签后的干净名字」。
    /// ⚠️ 从最近的一级往上找:嵌套时以**最靠近文件**的那个标签为准。
    private static func annotatedAncestorDirectory(_ path: String) -> (title: String, tmdbID: Int)? {
        var current = path
        while true {
            current = (current as NSString).deletingLastPathComponent
            let name = (current as NSString).lastPathComponent
            // 根(`/`)或空 → 到头了
            if name.isEmpty || name == "/" { return nil }
            guard let explicit = extractExplicitTMDBID(in: name) else { continue }
            let title = explicit.cleaned.trimmingCharacters(in: .whitespaces)
            // 目录名只剩一个标签 → 给不出剧名,不认(⛔ 不拿空串当剧名)
            guard !title.isEmpty else { return nil }
            return (title, explicit.id)
        }
    }

    /// 目录名是不是一个**季文件夹**,是就给出季号。
    ///
    /// 认这几种写法(整个目录名就是季标记,不含剧名):
    /// - `第13季`;
    /// - `Season 13` / `season13` / `Season.13`(`.` `_` `-` 与空格都当分隔符);
    /// - `S13` / `s2`。
    ///
    /// ⚠️ **季号 0 是合法值,不是「没解析出来」**:TMDB 的第 0 季是特别篇
    /// (`docs/TMDB_API.md` §7),标准命名库把特别篇放在 `Season 00/` / `S0/`。
    /// 所以这里认 `S0` / `Season 0` / `第0季`,返回 `0`。
    /// ⛔ 反过来说,调用方**不能**用「季号非 0」当「认出来了」的判据 ——
    /// 认没认出来要看返回值是不是 `nil`(Q43)。
    ///
    /// ⚠️ 只认**整个目录名**就是季标记的写法:剧名与季号挤在一起的目录名
    /// (`琅琊榜 第13季`)不认 —— 与 `剧名.01.mp4` 一样,无法可靠切分剧名与季号
    /// (S §6.3 的取舍:认不出来就不认,不猜)。中文数字(`第十三季`)同理不认。
    static func seasonNumber(fromDirectoryName name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        func number(_ text: Substring) -> Int? {
            // `>= 0`:第 0 季(特别篇)要认,见上面的说明
            guard let value = Int(text), value >= 0 else { return nil }
            return value
        }
        // `.` `_` `-` 与空格都当分隔符(`Season.13` / `season_13`)
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

    /// 文件名**整个**就是集号时返回那个号(`01.mp4` → 1)。
    ///
    /// 两种形态都算「整个文件名就是集号」:
    /// - 纯数字:`01.mp4`;
    /// - 集号 + 发布标记:`47-4K.高码率.mkv` → 47(集号后面**紧跟**发布标记)。
    ///
    /// ⚠️ 只认 1–3 位数字:4 位是年份的形状(`2012.mp4` 是一部电影),
    /// 带别的字的留给 `parse`(它知道发布标记从哪断)。
    ///
    /// ⚠️ 「集号 + 发布标记」是**弱信号**:`47-4K.高码率.mkv` 与电影发布名
    /// `300.1080p.BluRay.mkv` 结构完全一样,文件名本身分不出。所以调用方只在
    /// **同目录成串**时才把它当集号 —— 见 `seriesFolder` 的 `looksLikeEpisodeSequence` 闸门。
    static func bareEpisodeNumber(_ name: String) -> Int? {
        let base = baseName(name).trimmingCharacters(in: .whitespaces)
        // 纯数字:`01.mp4`
        if (1...3).contains(base.count), base.allSatisfy({ $0.isASCII && $0.isNumber }),
           let number = Int(base), number > 0 {
            return number
        }
        // 集号 + 发布标记:`47-4K.高码率.mkv`
        // 判据与 `parse` 一致:集号后面**紧跟**发布标记(`4K` / `1080p` …)。
        let tokens = tokenize(base)
        guard tokens.count >= 2, let first = tokens.first,
              (1...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(first), number > 0,
              isReleaseTag(tokens[1]) else {
            return nil
        }
        return number
    }

    /// 路径最后一级目录名(`/apps/x/琅琊榜/01.mp4` → `琅琊榜`)。
    /// 拿不到(路径没有目录,或就是根)时返回 `""`。
    private static func parentDirectoryName(_ path: String) -> String {
        directoryName(atLevel: 1, of: path)
    }

    /// 路径再上一级目录名(`/apps/x/琅琊榜/第13季/01.mp4` → `琅琊榜`)。
    /// 拿不到时返回 `""`。
    private static func grandparentDirectoryName(_ path: String) -> String {
        directoryName(atLevel: 2, of: path)
    }

    /// 从路径末尾往上数第 `level` 级目录名(`level = 1` 就是父目录)。
    private static func directoryName(atLevel level: Int, of path: String) -> String {
        var current = path
        for _ in 0..<level {
            current = (current as NSString).deletingLastPathComponent
        }
        let name = (current as NSString).lastPathComponent
        // 根目录时 `lastPathComponent` 是 `/`,那不是个名字
        return name == "/" ? "" : name
    }

    // MARK: - 文件名解析

    /// 从名称里抠出**显式写死的 TMDB id**,并返回剥掉该标签后的名称。
    ///
    /// 认 tinyMediaManager / Jellyfin / Kodi 一类媒体库的标准命名:
    /// `{tmdbid-63926}` / `[tmdbid-63926]` / `(tmdbid-63926)` / 裸写的 `tmdbid-63926`,
    /// 键名 `tmdbid` 或 `tmdb`(大小写不敏感),分隔符 `-` 或 `=`。
    ///
    /// ⚠️ 标签只给 id,**不给「这是电影还是剧」** —— TMDB 两个 id 空间各自编号,
    /// 所以这里只回答「是哪个 id」,由刮削层按上下文决定查哪个端点。
    ///
    /// 返回 `nil` = 名称里没有这个标签。有标签但数字读不出(超 `Int` 范围)也当没有。
    static func extractExplicitTMDBID(in name: String) -> (id: Int, cleaned: String)? {
        // 带括号包裹的先试:`[\[{(]\s*tmdb…\s*[\])}]` —— 整段连括号一起剥掉
        if let match = name.firstMatch(of: /[\[{(]\s*(?i:tmdbid|tmdb)\s*[-=]\s*(\d{1,9})\s*[\])}]/),
           let id = Int(match.1) {
            return (id, removing(match.range, from: name))
        }
        // 裸写:`tmdbid-63926`
        if let match = name.firstMatch(of: /(?i:tmdbid|tmdb)\s*[-=]\s*(\d{1,9})/),
           let id = Int(match.1) {
            return (id, removing(match.range, from: name))
        }
        return nil
    }

    /// 删掉一段匹配区间,并把因此留下的多余空白收成一个空格。
    private static func removing(_ range: Range<String.Index>, from name: String) -> String {
        var text = name
        text.removeSubrange(range)
        return text
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// 从文件名解析标题 / 年份 / 季集。
    ///
    /// 规则(顺序即优先级):
    /// 0. **显式 TMDB id**:`{tmdbid-63926}` —— 先抠出 id 并从名称里剥掉(见上),
    ///    它不参与标题;
    /// 1. **季集**:`S01E02` / `E02` / `第01集` —— 命中就把条目判成剧集;
    /// 2. **年份**:4 位数且在 `1900...2099`,**且后面紧跟发布标记或到此为止**。
    ///    这条约束是关键:片名里也可能有 4 位数字(`1917`),
    ///    但它后面跟的是另一个数字而不是 `1080p`,所以不会被误判成上映年;
    /// 3. **发布标记**:命中即截断,后面的都是编码 / 音轨 / 语言信息。
    static func parse(name: String) -> ParsedName {
        let base = (name as NSString).deletingPathExtension
        // 名称里写死的显式 TMDB id(`{tmdbid-63926}`)先抠出来、并从标题里剥掉 ——
        // 它是元数据,不是片名的一部分(见 `extractExplicitTMDBID`)。
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

    /// 归一化分隔符后切成 token(`47-4K.高码率` → `["47", "4K", "高码率"]`)。
    ///
    /// 发布组习惯用 `.` 与 `_`(`Some.Movie.2019.1080p.mkv`),括号只包着年份
    /// (`Some.Movie.(2019)`),去掉不影响别的。`-` 与空格、制表符一样当分隔符。
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

    private static func seasonEpisode(in token: String) -> (season: Int?, episode: Int)? {
        if let match = token.wholeMatch(of: /[Ss](\d{1,2})[Ee](\d{1,3})/),
           let season = Int(match.1), let episode = Int(match.2) {
            return (season, episode)
        }
        // ⚠️ 下面两种只带集号、**不带季号** —— 季返回 `nil`。
        // ⛔ 不要用 0 当「不知道」的哨兵:TMDB 的**第 0 季是特别篇**(`docs/TMDB_API.md` §7),
        // 拿 0 当「不知道」会让特别篇与「没写季号」混成同一件事。
        if let match = token.wholeMatch(of: /[Ee][Pp]?(\d{1,3})/), token.count <= 4 {
            return (nil, Int(match.1) ?? 0)
        }
        if let match = token.wholeMatch(of: /第(\d{1,3})[集话話]/) {
            return (nil, Int(match.1) ?? 0)
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
        "字幕", "内嵌", "外挂", "高清", "蓝光", "修复版", "高码率", "高碼率",
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
