import Foundation

/// 百度网盘**剧集目录 → 标准 TMDB 命名**的改名计划生成器(**纯函数**)。
///
/// ## 它解决什么
///
/// 网盘里常见这种存法 —— 目录名是剧名、季目录只写个 `S0`、文件只是集号:
///
/// ```
/// 一拳超人/
///   S0/01.mp4
///   S1/01.mp4  02.mp4
/// ```
///
/// 这种名字进不了 Plex / Emby / Jellyfin 的标准库(认不出是哪一季哪一集),
/// 而**改名的依据(剧名 / 首播年 / 集标题)在 TMDB 上**,不在文件名里。
/// 所以这一步把「目录树 + TMDB 给的权威身份」折成一份**改名计划**:
///
/// ```
/// 一拳超人 (2015) {tmdbid-63926}/
///   Season 00/一拳超人 (2015) - S00E01 - 集标题.mp4
///   Season 01/一拳超人 (2015) - S01E01 - 集标题.mp4
/// ```
///
/// ## 平铺存法(只有一季)
///
/// 另一种常见存法是**整部剧平铺在剧根下**,连季目录都没有:
///
/// ```
/// 一拳超人/01.mp4  02.mp4  03.mp4
/// ```
///
/// 这种按**第 1 季**处理,而且**不新建季目录** —— 就一季,再套一层 `Season 01`
/// 只是徒增一层(标准库认「剧根下直接是集文件」为第 1 季):
///
/// ```
/// 一拳超人 (2015) {tmdbid-63926}/
///   一拳超人 (2015) - S01E01 - 集标题.mp4
///   一拳超人 (2015) - S01E02 - 集标题.mp4
/// ```
///
/// ## 它不是什么
///
/// ⛔ **不联网、不发请求、不改任何东西**。TMDB 的查询由调用方做
/// (`TMDBClient` + `BaiduPanMetadataScraper` 已有的搜索 / 季详情),
/// 百度侧的提交由执行器做。这一层只是「给定事实 → 算出该叫什么」,
/// 所以要能脱离网络、用 fixture 单测。
///
/// ## 三条硬纪律(与 `BaiduPanMetadataScraper` 同口径)
///
/// 1. **不伪造**。TMDB 没给集标题 → 名字里就不带那一段(`- S01E01.mp4`),
///    ⛔ 不拿「第 1 集」或剧名去填(CLAUDE.md 硬规则 4)。
/// 2. **不静默吞错**。认不出集号的文件**不改名**,而是进 `skipped` 并写明原因;
///    ⛔ 不给认不出的东西编一个名字。
/// 3. **不猜季号**。剧根目录下直接平铺的集文件**一律当第 1 季**(平铺 = 只有一季,
///    见上一节),这是**判据**不是猜;但剧根下**同时**有季文件夹时,散着的文件
///    属于哪一季就答不了了 → 跳过,⛔ 不默认第 1 季(`S0` 特别篇就是反例)。
///
/// ## 命名规则
///
/// | 目标 | 格式 |
/// |---|---|
/// | 剧根 | `{剧名} ({首播年}) {tmdbid-{id}}`,无年份时省掉括号段 |
/// | 季目录 | `Season {季:02}`(`S0` → `Season 00`);平铺存法**不建**季目录 |
/// | 集文件 | `{剧名} ({首播年}) - S{季:02}E{集:02} - {集标题}.{ext}` |
///
/// ⚠️ 年份取 TMDB 的**首播年**,不是文件名里的数字 —— 发布组命名里的
/// `2025` 往往是当季发布年(`一拳超人.ONE PUNCH MAN.2025.S00E15…`),拿它当首播年会错。
enum BaiduPanRenamePlanner {

    /// 这部剧在 TMDB 上的身份。**必须由调用方确定后传进来** ——
    /// ⛔ 本层不负责「搜到的是不是这部剧」(那要人确认,猜不得)。
    struct SeriesIdentity: Sendable, Equatable {
        let tmdbID: Int
        /// TMDB 给的剧名(已按 `language` 取好)。可能含 `:`,命名时会清洗。
        let title: String
        /// 首播年。`nil` = TMDB 没给,名字里就不带年份段。

        let year: Int?

        init(tmdbID: Int, title: String, year: Int?) {
            self.tmdbID = tmdbID
            self.title = title
            self.year = year
        }

        /// 名字里共用的前缀:`一拳超人 (2015)`。TMDB 剧名里的非法字符在这里就洗掉。
        var prefix: String {
            let clean = BaiduPanRenamePlanner.sanitize(title)
            guard let year else { return clean }
            return "\(clean) (\(year))"
        }
    }

    /// 改哪一类东西。
    ///
    /// ⚠️ `order` 就是**执行顺序**:百度 `opera=rename` 用 `path` 定位,
    /// 父目录一改名,子文件的 `path` 立刻失效。所以必须**自底向上**提交:
    /// 集文件 → 季目录 → 剧根。
    enum Target: Sendable, Equatable {
        case episodeFile
        case seasonDirectory
        case seriesDirectory

        var order: Int {
            switch self {
            case .episodeFile: return 0
            case .seasonDirectory: return 1
            case .seriesDirectory: return 2
            }
        }
    }

    /// 一条改名。**已确认要改的** —— 跳过的不在这里,在 `Plan.skipped`。
    struct Item: Sendable, Equatable {
        let fsID: UInt64
        /// 提交 rename 时用的**当前**路径(改完它就失效了)
        let oldPath: String
        let oldName: String
        let newName: String
        let target: Target
        let season: Int?
        let episode: Int?

        /// 新旧同名 = 已经是标准命名,执行器应当**跳过不提交**(省一次请求、也省配额)。
        var isUnchanged: Bool { oldName == newName }
    }

    /// 跳过原因。⛔ 每一条都要写清「为什么不改」 —— UI 要原样显示给用户看。
    enum SkipReason: Sendable, Equatable {
        /// 不是音视频(字幕 / 封面 / `nfo`):不是本功能的对象,不动它。
        case notPlayable
        /// 文件名认不出集号(`花絮.mp4`)。
        case episodeNumberUnknown
        /// 剧根下既有季文件夹、又散着文件 → 散着的那些属于哪一季无从判断。
        ///
        /// ⚠️ 只在**混放**时出现。剧根下**只有**平铺文件(没有任何季文件夹)时
        /// 是「只有一季」,按第 1 季处理,不走这条。
        case seasonAmbiguous
        /// 改名后会与同目录里已存在的条目撞名。
        case duplicateTargetName
        /// 清洗后名字为空(剧名整个是非法字符这类极端情况)。
        case emptyTargetName

        var description: String {
            switch self {
            case .notPlayable: return "不是音视频文件,不改名"
            case .episodeNumberUnknown: return "文件名认不出集号"
            case .seasonAmbiguous: return "剧根下与季文件夹混放,这个文件属于哪一季无法确定"
            case .duplicateTargetName: return "改名后会与同目录已有条目重名"
            case .emptyTargetName: return "清洗后名字为空"
            }
        }
    }

    /// 一条被跳过的条目。
    struct Skipped: Sendable, Equatable {
        let fsID: UInt64
        let path: String
        let reason: SkipReason
    }

    /// 一份改名计划。
    struct Plan: Sendable, Equatable {
        /// 已按**执行顺序**排好(集文件 → 季目录 → 剧根)。
        let items: [Item]
        /// 跳过的条目与原因。⛔ UI 必须显示 —— 静默跳过等于骗用户「全改好了」。
        let skipped: [Skipped]
        /// 这部剧是**平铺**的:剧根下没有季文件夹,集文件直接堆在剧根。
        ///
        /// 这种按第 1 季处理,且**不新建**季目录 —— UI 要把这件事说出来,
        /// 否则用户看到 `S01` 会以为漏建了一层。
        let isFlat: Bool

        /// 真正要提交的数量(不含已经同名的)。
        var actionableCount: Int { items.filter { !$0.isUnchanged }.count }
    }

    // MARK: - 入口

    /// 生成一份改名计划。
    ///
    /// - Parameters:
    ///   - root: 剧根目录本身(会被改名为带 `{tmdbid-N}` 的标准名)。
    ///   - entries: 递归列出来的**整棵树**(含 `root` 自己及其所有后代),来自 `method=list`。
    ///   - identity: 这部剧在 TMDB 上的身份(调用方确认过的)。
    ///   - episodeTitles: `[季号: [集号: 集标题]]`。查不到就传空字典 —— 名字里
    ///     只是不带集标题段,⛔ 不影响其它部分。
    static func makePlan(
        root: BaiduPanFile,
        entries: [BaiduPanFile],
        identity: SeriesIdentity,
        episodeTitles: [Int: [Int: String]] = [:]
    ) -> Plan {
        let prefix = identity.prefix
        var candidates: [Item] = []
        var skipped: [Skipped] = []

        // 剧根:标准名带权威 id,下次再进来就不用重新认剧了(Q25 的同一思路)
        candidates.append(Item(
            fsID: root.fsID,
            oldPath: root.path,
            oldName: root.name,
            newName: "\(prefix) {tmdbid-\(identity.tmdbID)}",
            target: .seriesDirectory,
            season: nil,
            episode: nil
        ))

        let children = entries.filter { parentPath(of: $0.path) == root.path }
        let flatFiles = children.filter { !$0.isDirectory }
        let seasonDirectories = Self.seasonDirectories(in: entries, root: root)

        // 剧根下**一个季文件夹都没有** = 整部剧平铺 = 只有一季 → 一律当第 1 季,
        // 且**不建**季目录(见类型注释「平铺存法」)。
        let isFlat = seasonDirectories.isEmpty && flatFiles.contains { $0.kind.isPlayable }

        if isFlat {
            appendEpisodes(
                files: flatFiles, season: 1, prefix: prefix,
                episodeTitles: episodeTitles, into: &candidates, skipped: &skipped)
        } else {
            // 有季文件夹,剧根下还散着可播放文件 → 它们属于哪一季答不了,跳过(⛔ 不猜)
            for file in flatFiles where file.kind.isPlayable {
                skipped.append(Skipped(fsID: file.fsID, path: file.path, reason: .seasonAmbiguous))
            }

            for (directory, season) in seasonDirectories {
                let files = entries.filter { parentPath(of: $0.path) == directory.path }
                appendEpisodes(
                    files: files, season: season, prefix: prefix,
                    episodeTitles: episodeTitles, into: &candidates, skipped: &skipped)

                candidates.append(Item(
                    fsID: directory.fsID,
                    oldPath: directory.path,
                    oldName: directory.name,
                    newName: "Season \(padded(season))",
                    target: .seasonDirectory,
                    season: season,
                    episode: nil
                ))
            }
        }

        return Plan(items: resolved(candidates, entries: entries, skipped: &skipped),
                    skipped: skipped,
                    isFlat: isFlat)
    }

    /// 剧根**下一层**里能认出季号的目录(`S1` / `Season 2` / `第3季`),按名字排好。
    ///
    /// ⛔ 认不出的目录(剧名与季号挤在一起、或干脆不是季目录)不在这里 ——
    /// 那种情况下集文件走「平铺」判据,而不是猜一个季号。
    static func seasonDirectories(
        in entries: [BaiduPanFile],
        root: BaiduPanFile
    ) -> [(file: BaiduPanFile, season: Int)] {
        entries
            .compactMap { entry -> (file: BaiduPanFile, season: Int)? in
                guard entry.isDirectory,
                      parentPath(of: entry.path) == root.path,
                      let season = BaiduPanMetadataSynthesizer.seasonNumber(
                          fromDirectoryName: entry.name)
                else { return nil }
                return (entry, season)
            }
            .sorted { $0.file.name < $1.file.name }
    }

    /// 这部剧**可能涉及**的季号 —— 拿去问 TMDB 要分集表用(`seasonDetails`)。
    ///
    /// - 有季目录 → 就是那些季;
    /// - 剧根下平铺(没有季目录)→ 只可能是第 1 季(与 `makePlan` 同一判据);
    /// - 剧根下一个文件都没有 → 空,⛔ 不问 —— 那是一次白发的请求。
    static func seasonNumbers(in entries: [BaiduPanFile], root: BaiduPanFile) -> [Int] {
        let seasons = seasonDirectories(in: entries, root: root).map(\.season)
        if !seasons.isEmpty { return Array(Set(seasons)).sorted() }
        let hasFlatFile = entries.contains {
            !$0.isDirectory && parentPath(of: $0.path) == root.path
        }
        return hasFlatFile ? [1] : []
    }

    /// 把一批文件折成集文件改名项。
    ///
    /// - Parameter season: 由调用方给定 —— 季目录认出来的季号,或平铺时的 `1`。
    ///   ⛔ 不从文件名里取:文件名里的 `S01` 与它在网盘里的位置可能不一致。
    private static func appendEpisodes(
        files: [BaiduPanFile],
        season: Int,
        prefix: String,
        episodeTitles: [Int: [Int: String]],
        into candidates: inout [Item],
        skipped: inout [Skipped]
    ) {
        for file in files.sorted(by: { $0.name < $1.name }) {
            guard file.kind.isPlayable else {
                skipped.append(Skipped(fsID: file.fsID, path: file.path, reason: .notPlayable))
                continue
            }
            guard let episode = episodeNumber(of: file) else {
                skipped.append(Skipped(
                    fsID: file.fsID, path: file.path, reason: .episodeNumberUnknown))
                continue
            }
            let stem = episodeStem(
                prefix: prefix, season: season, episode: episode,
                title: episodeTitles[season]?[episode])
            candidates.append(Item(
                fsID: file.fsID,
                oldPath: file.path,
                oldName: file.name,
                newName: "\(stem).\(fileExtension(of: file))",
                target: .episodeFile,
                season: season,
                episode: episode
            ))
        }
    }

    // MARK: - 命名

    /// 集文件的名字主干(不含扩展名)。
    ///
    /// ⚠️ 集标题**拿不到就不带那一段**(`- S01E01.mp4`),⛔ 不用「第 N 集」顶上。
    static func episodeStem(prefix: String, season: Int, episode: Int, title: String?) -> String {
        let marker = "S\(padded(season))E\(padded(episode))"
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(prefix) - \(marker)"
        }
        return "\(prefix) - \(marker) - \(sanitize(title))"
    }

    /// 两位补零(`0` → `00`,`13` → `13`,`100` → `100`)。
    ///
    /// ⚠️ 用 `%02d` 而不是手动拼:集号超过 99 时不能截断成两位。
    static func padded(_ number: Int) -> String {
        String(format: "%02d", number)
    }

    // MARK: - 冲突处理

    /// 去掉会撞名的候选,并按执行顺序排序。
    ///
    /// 判据是「改名**之后**同目录里的名字集合」:先把参与改名的旧名从占用表里摘掉,
    /// 再放新名 —— 放不进去(已存在)就是冲突。
    ///
    /// ⚠️ 冲突时**全部**跳过,⛔ 不保留第一个:同目录两个文件算出同一个名字
    /// (`01.mp4` 与 `1.mp4` 都是第 1 集),说明「哪个才是这一集」数据本身就答不了,
    /// 挑一个是猜。所以要**两遍**:先标出所有冲突,再统一剔除,
    /// 而不是边走边判(那样先到的那个会被留下)。
    private static func resolved(
        _ candidates: [Item],
        entries: [BaiduPanFile],
        skipped: inout [Skipped]
    ) -> [Item] {
        // 父目录 → 当前占用的名字
        var occupied: [String: Set<String>] = [:]
        for entry in entries {
            occupied[parentPath(of: entry.path), default: []].insert(entry.name)
        }
        // 即将消失的旧名先摘掉。⛔ `isUnchanged` 的不摘 —— 它改完还叫这个名字,
        // 摘了就会让别人误以为这个名字是空着的。
        var taken = occupied
        for candidate in candidates where !candidate.isUnchanged {
            taken[parentPath(of: candidate.oldPath)]?.remove(candidate.oldName)
        }

        // 第一遍:标出冲突(parent + 新名 为键,同一键的第二条起都算冲突)
        var conflicting: Set<String> = []
        for candidate in candidates {
            guard !candidate.isUnchanged, !candidate.newName.isEmpty else { continue }
            let parent = parentPath(of: candidate.oldPath)
            let key = conflictKey(parent: parent, name: candidate.newName)
            if taken[parent, default: []].contains(candidate.newName) || conflicting.contains(key) {
                conflicting.insert(key)
            } else {
                taken[parent, default: []].insert(candidate.newName)
            }
        }

        // 第二遍:剔除冲突项
        var kept: [Item] = []
        for candidate in candidates {
            let name = candidate.newName
            guard !name.isEmpty else {
                skipped.append(Skipped(
                    fsID: candidate.fsID, path: candidate.oldPath, reason: .emptyTargetName))
                continue
            }
            if !candidate.isUnchanged,
               conflicting.contains(conflictKey(
                   parent: parentPath(of: candidate.oldPath), name: name)) {
                skipped.append(Skipped(
                    fsID: candidate.fsID, path: candidate.oldPath, reason: .duplicateTargetName))
                continue
            }
            kept.append(candidate)
        }

        return kept.sorted { lhs, rhs in
            if lhs.target.order != rhs.target.order { return lhs.target.order < rhs.target.order }
            return lhs.oldPath < rhs.oldPath
        }
    }

    /// 冲突键:`父路径 + 新名`。用控制字符分隔 —— 路径里不会出现它,
    /// ⛔ 直接拼字符串会让 `/a/b` + `c` 与 `/a` + `/bc` 撞成同一个键。
    private static func conflictKey(parent: String, name: String) -> String {
        "\(parent)\u{1}\(name)"
    }

    // MARK: - 小工具

    /// 集号:文件名里明确的 `SxxExx` / `第N集` 优先,否则整个文件名就是集号(`01.mp4`)。
    ///
    /// ⛔ 复用合成器已有的两个纯函数,不在这里另写一套解析 —— 改名后的名字必须
    /// 与「App 认它为第几集」一致,否则改名反而改错了集号。
    static func episodeNumber(of file: BaiduPanFile) -> Int? {
        BaiduPanMetadataSynthesizer.parse(name: file.name).episode
            ?? BaiduPanMetadataSynthesizer.bareEpisodeNumber(file.name)
    }

    /// 保留原始大小写的扩展名(`MP4` 不硬改成 `mp4` —— 那是一次没必要的改动)。
    static func fileExtension(of file: BaiduPanFile) -> String {
        (file.path as NSString).pathExtension
    }

    static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// 洗成能进网盘文件名的样子。
    ///
    /// 三件事:
    /// 1. 非法字符(`/ \ : * ? " < > |`)**换成空格**而不是删掉 ——
    ///    `第1集:归来` 变 `第1集 归来` 比变 `第1集归来` 更接近原意;
    /// 2. 换行 / 制表符收成空格,首尾空格与结尾的点去掉(Windows 系不接受以点或空格结尾);
    /// 3. 按**字节**截断 —— 中文一个字 3 字节,按字符数截会截出能看但不合规的长名。
    ///
    /// ⚠️ 上限 `maxBytes` 是个保守值:百度自己的文件名上限没在开放平台文档里写明,
    /// ⛔ 不声称「已按百度上限校验」。
    static func sanitize(_ text: String, maxBytes: Int = 180) -> String {
        let banned: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var scalarText = String(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        scalarText = String(scalarText.map { banned.contains($0) ? " " : $0 })
        let collapsed = scalarText
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmed = collapsed.trimmingCharacters(in: [" ", "."])

        var result = ""
        var bytes = 0
        for character in trimmed {
            let width = String(character).utf8.count
            guard bytes + width <= maxBytes else { break }
            result.append(character)
            bytes += width
        }
        return result
    }
}
