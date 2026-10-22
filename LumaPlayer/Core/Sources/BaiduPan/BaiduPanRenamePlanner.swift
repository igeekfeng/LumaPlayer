import Foundation

/// 剧集目录 → 标准 TMDB 命名的改名计划(纯函数)。⛔ 不联网、不改任何东西:
/// TMDB 查询由调用方做,百度侧提交由执行器做。
///
/// ```
/// 一拳超人/S0/01.mp4, S1/01.mp4    →  一拳超人 (2015) {tmdbid-63926}/Season 00/一拳超人 (2015) - S00E01 - 集标题.mp4
/// 一拳超人/01.mp4 02.mp4(平铺)   →  一拳超人 (2015) {tmdbid-63926}/一拳超人 (2015) - S01E01 - 集标题.mp4
/// ```
///
/// | 目标 | 格式 |
/// |---|---|
/// | 剧根 | `{剧名} ({首播年}) {tmdbid-{id}}`,无年份时省掉括号段 |
/// | 季目录 | `Season {季:02}`;平铺存法不建季目录 |
/// | 集文件 | `{剧名} ({首播年}) - S{季:02}E{集:02} - {集标题}.{ext}` |
///
/// - 没有集标题 → 不带那一段,⛔ 不拿「第 N 集」或剧名填(`CLAUDE.md` 硬规则 4)。
/// - 认不出集号的不改名,进 `skipped` 写明原因。
/// - 剧根下只有平铺文件 = 第 1 季;剧根下同时有季文件夹时散着的文件跳过,⛔ 不默认第 1 季。
/// - 年份取 TMDB 首播年,⛔ 不取文件名里的数字(发布组名里的年份常是当季发布年)。
enum BaiduPanRenamePlanner {

    /// 由调用方确认后传入;本层不判断搜到的是不是这部剧。
    struct SeriesIdentity: Sendable, Equatable {
        let tmdbID: Int
        /// 可能含 `:`,命名时清洗
        let title: String
        /// 首播年;nil 时名字不带年份段
        let year: Int?

        init(tmdbID: Int, title: String, year: Int?) {
            self.tmdbID = tmdbID
            self.title = title
            self.year = year
        }

        /// `一拳超人 (2015)`,已清洗
        var prefix: String {
            let clean = BaiduPanRenamePlanner.sanitize(title)
            guard let year else { return clean }
            return "\(clean) (\(year))"
        }
    }

    /// `order` 是执行顺序:`opera=rename` 按 `path` 定位,父目录先改子路径就失效,
    /// 必须自底向上(集文件 → 季目录 → 剧根)。
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

    /// 跳过的在 `Plan.skipped`
    struct Item: Sendable, Equatable {
        let fsID: UInt64
        /// 当前路径,改完即失效
        let oldPath: String
        let oldName: String
        let newName: String
        let target: Target
        let season: Int?
        let episode: Int?

        /// 已是标准命名,执行器不提交(省配额)
        var isUnchanged: Bool { oldName == newName }
    }

    /// UI 原样显示给用户
    enum SkipReason: Sendable, Equatable {
        /// 字幕 / 封面 / `nfo` 等
        case notPlayable
        case episodeNumberUnknown
        /// 只在剧根下季文件夹与散文件混放时出现
        case seasonAmbiguous
        case duplicateTargetName
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

    struct Skipped: Sendable, Equatable {
        let fsID: UInt64
        let path: String
        let reason: SkipReason
    }

    struct Plan: Sendable, Equatable {
        /// 已按执行顺序排好
        let items: [Item]
        /// ⛔ UI 必须显示,不能静默跳过
        let skipped: [Skipped]
        /// 剧根下没有季文件夹:按第 1 季、不建季目录。UI 要说明,否则用户以为漏建了一层。
        let isFlat: Bool

        /// 不含已同名的
        var actionableCount: Int { items.filter { !$0.isUnchanged }.count }
    }

    // MARK: - 入口

    /// - Parameters:
    ///   - entries: 递归列出的整棵树(含 `root` 及所有后代)
    ///   - episodeTitles: `[季号: [集号: 集标题]]`,查不到传空,只是不带集标题段
    static func makePlan(
        root: BaiduPanFile,
        entries: [BaiduPanFile],
        identity: SeriesIdentity,
        episodeTitles: [Int: [Int: String]] = [:]
    ) -> Plan {
        let prefix = identity.prefix
        var candidates: [Item] = []
        var skipped: [Skipped] = []

        // 剧根名带 tmdbid,下次进来不用重新认剧(Q25)
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

        let isFlat = seasonDirectories.isEmpty && flatFiles.contains { $0.kind.isPlayable }

        if isFlat {
            appendEpisodes(
                files: flatFiles, season: 1, prefix: prefix,
                episodeTitles: episodeTitles, into: &candidates, skipped: &skipped)
        } else {
            // 散在剧根下的可播放文件:季号答不了,跳过
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

    /// 剧根下一层能认出季号的目录(`S1` / `Season 2` / `第3季`),按名字排。认不出的不猜。
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

    /// 要向 TMDB 查分集表(`seasonDetails`)的季号,判据同 `makePlan`;剧根下没文件时为空,不白发请求。
    static func seasonNumbers(in entries: [BaiduPanFile], root: BaiduPanFile) -> [Int] {
        let seasons = seasonDirectories(in: entries, root: root).map(\.season)
        if !seasons.isEmpty { return Array(Set(seasons)).sorted() }
        let hasFlatFile = entries.contains {
            !$0.isDirectory && parentPath(of: $0.path) == root.path
        }
        return hasFlatFile ? [1] : []
    }

    /// - Parameter season: 来自所在位置(季目录或平铺的 1),⛔ 不从文件名取:文件名里的 `S01` 可能与位置不符。
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

    /// 不含扩展名
    static func episodeStem(prefix: String, season: Int, episode: Int, title: String?) -> String {
        let marker = "S\(padded(season))E\(padded(episode))"
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(prefix) - \(marker)"
        }
        return "\(prefix) - \(marker) - \(sanitize(title))"
    }

    /// 至少两位,超过 99 不截断
    static func padded(_ number: Int) -> String {
        String(format: "%02d", number)
    }

    // MARK: - 冲突处理

    /// 去掉会撞名的候选并按执行顺序排序。判据是改名之后同目录的名字集合。
    ///
    /// 冲突的全部跳过,⛔ 不保留第一个(`01.mp4` 与 `1.mp4` 都算第 1 集时挑一个就是猜),
    /// 所以分两遍:先标冲突,再统一剔除。
    private static func resolved(
        _ candidates: [Item],
        entries: [BaiduPanFile],
        skipped: inout [Skipped]
    ) -> [Item] {
        var occupied: [String: Set<String>] = [:]
        for entry in entries {
            occupied[parentPath(of: entry.path), default: []].insert(entry.name)
        }
        // 摘掉即将消失的旧名;`isUnchanged` 的不摘,它改完还占着这个名字
        var taken = occupied
        for candidate in candidates where !candidate.isUnchanged {
            taken[parentPath(of: candidate.oldPath)]?.remove(candidate.oldName)
        }

        // 第一遍:标出冲突
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

    /// 用路径里不会出现的控制字符分隔,直接拼会让 `/a/b`+`c` 与 `/a`+`/bc` 撞键
    private static func conflictKey(parent: String, name: String) -> String {
        "\(parent)\u{1}\(name)"
    }

    // MARK: - 小工具

    /// ⛔ 复用合成器的解析,不另写一套:改名结果必须与 App 认的集号一致。
    static func episodeNumber(of file: BaiduPanFile) -> Int? {
        BaiduPanMetadataSynthesizer.parse(name: file.name).episode
            ?? BaiduPanMetadataSynthesizer.bareEpisodeNumber(file.name)
    }

    /// 保留原始大小写
    static func fileExtension(of file: BaiduPanFile) -> String {
        (file.path as NSString).pathExtension
    }

    static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// 非法字符换成空格(不删,保留分词);去首尾空格与点;按 UTF-8 字节截断。
    /// `maxBytes` 是保守值,百度文件名上限未见文档,⛔ 不声称已按百度上限校验。
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
