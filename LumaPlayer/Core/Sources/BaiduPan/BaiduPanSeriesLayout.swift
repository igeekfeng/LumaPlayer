import Foundation

/// 一个目录的**内容形态**:普通目录(继续网格浏览),还是一部剧(进详情页)。
///
/// ## 为什么需要它
///
/// 百度网盘没有 Emby 那种「媒体库 → 剧 → 季 → 集」的服务端结构,只有目录树。
/// 但用户在网盘里的**存法本身**已经表达了这个结构(`docs/SOURCE_ABSTRACTION_PLAN.md` §6.3):
///
/// ```
/// 琅琊榜/01.mp4、02.mp4、…            剧目录下直接摆着集文件 = 第 1 季
/// 琅琊榜/第1季/01.mp4、第2季/…        剧目录下是季文件夹 = 一层一季
/// ```
///
/// 点进这种目录时,用户期望看到的是 **Emby 那样的剧集详情页**(海报 / 简介 / 季 / 分集),
/// 而不是又一层文件网格。判定放在这里(纯函数、不认识网络),界面只按结果分派。
enum BaiduPanDirectoryShape: Equatable, Sendable {
    /// 普通目录:继续网格浏览(片库里的分类目录、电影目录都走这条)
    case directory
    /// 一部剧:进详情页
    case series(BaiduPanSeriesStructure)

    /// 是剧集时给出它的季结构,否则 nil
    var seriesStructure: BaiduPanSeriesStructure? {
        if case .series(let structure) = self { return structure }
        return nil
    }

    /// 是不是剧集形态
    var isSeries: Bool { seriesStructure != nil }
}

/// 一部剧的季结构。
struct BaiduPanSeriesStructure: Equatable, Sendable {
    /// 季列表,已排序:有季号的按季号升序,「未分季」排最后。**至少一季**。
    let seasons: [BaiduPanSeason]

    /// 只有一季时详情页不显示季选择器(一屏全是一集的横排,再挂个「第 1 季」下拉没有意义)
    var isSingleSeason: Bool { seasons.count <= 1 }
}

/// 一季。
struct BaiduPanSeason: Equatable, Sendable, Identifiable {
    /// 季号。`nil` = **未分季**。
    ///
    /// 什么时候会没有季号:剧目录里既摆着平铺的集文件、又有季文件夹(罕见存法)——
    /// 平铺的那批没有季号可归。这时单列一季而不是丢掉(`CLAUDE.md` 硬规则 4)。
    let number: Int?
    /// 展示名:`第 N 季` / `特别篇`(第 0 季)/ `未分季`
    let title: String
    /// 这一季的分集从哪来
    let source: Source

    /// 分集的载体。
    ///
    /// ⚠️ 这两条路的**请求代价完全不同**,所以必须分开表达:季文件夹要**另外列一次**
    /// 那个目录才知道里面有什么(百度配额,见 `docs/BAIDU_PAN_API.md` §7);
    /// 平铺的集文件在列剧目录时就已经拿到了,零额外请求。
    enum Source: Equatable, Sendable {
        /// 季文件夹 —— 分集要另外列一次这个目录
        case folder(SourceItem)
        /// 平铺在剧目录里的集文件 —— 已经在手上
        case flatFiles([SourceItem])
    }

    var id: String {
        number.map(String.init) ?? Self.unassignedID
    }

    /// 「未分季」那一季的固定 id(季号是 nil,不能拿它当 id)
    static let unassignedID = "unassigned"

    /// 季标题。
    ///
    /// ⚠️ 第 0 季是 TMDB 口径的**特别篇**(`docs/TMDB_API.md` §7),标准命名库把它放在
    /// `Season 00/` / `S0/`。所以季号 0 不是「没解析出来」,要如实叫「特别篇」。
    static func title(forSeason number: Int?) -> String {
        guard let number else { return "未分季" }
        return number == 0 ? "特别篇" : "第 \(number) 季"
    }
}

/// 目录形态的判定(纯函数,可单测)。
///
/// ⛔ 它**不认识网络**,也不认识 `BaiduPanFile` —— 只看合成之后的 `[SourceItem]`。
/// 判定用的两条线索(季号、集号)都来自 `BaiduPanMetadataSynthesizer` 的文件名 / 目录名解析。
enum BaiduPanSeriesLayout {

    /// 这一层目录**是不是一部剧**。
    ///
    /// 判据(按优先级;⛔ 两条都不放宽 —— 认不出来就当普通目录,不猜):
    ///
    /// 1. **有季文件夹**(目录名整个就是季标记:`第13季` / `Season 2` / `S0`):
    ///    这些子目录就是这一部剧的各季。季号复用合成器的
    ///    `BaiduPanMetadataSynthesizer.seasonNumber(fromDirectoryName:)`,只认**整个目录名**
    ///    就是季标记的写法 —— `琅琊榜 第13季` 这种剧名与季号挤在一起的不认(切不干净,不猜)。
    /// 2. **否则,这一层有剧集条目**(`kind == .episode`):剧目录下直接摆着集文件,
    ///    按用户口径就是**第 1 季**。
    ///    ⚠️ 这里能安全地把「有集文件」当成「这是一部剧」,靠的是合成器已经用
    ///    **「同目录 ≥2 个集号型文件名」**的闸门把平铺的电影排除了
    ///    (`looksLikeEpisodeSequence`)—— 孤零零一个 `300.mp4` 不会得到 `.episode`。
    ///
    /// 两条都不满足 → `.directory`。**这一条必须有**:片库里的「电影」「纪录片」这类
    /// 分类目录下面全是子目录,若无条件当剧集,整个片库都会被误判成一部剧。
    static func shape(of items: [SourceItem]) -> BaiduPanDirectoryShape {
        let seasonFolders = items
            .compactMap { item -> (item: SourceItem, season: Int)? in
                guard item.kind == .folder, let season = item.seasonNumber else { return nil }
                return (item, season)
            }
            .sorted { $0.season < $1.season }
        let flatEpisodes = sortedEpisodes(items.filter { $0.kind == .episode })

        guard !seasonFolders.isEmpty else {
            guard !flatEpisodes.isEmpty else { return .directory }
            return .series(BaiduPanSeriesStructure(seasons: [
                BaiduPanSeason(
                    number: 1,
                    title: BaiduPanSeason.title(forSeason: 1),
                    source: .flatFiles(flatEpisodes))
            ]))
        }

        var seasons = seasonFolders.map { entry in
            BaiduPanSeason(
                number: entry.season,
                title: BaiduPanSeason.title(forSeason: entry.season),
                source: .folder(entry.item))
        }
        // 季文件夹与平铺文件并存:平铺的那批单列一季 —— ⛔ 不静默吞掉(`CLAUDE.md` 硬规则 4)
        if !flatEpisodes.isEmpty {
            seasons.append(BaiduPanSeason(
                number: nil,
                title: BaiduPanSeason.title(forSeason: nil),
                source: .flatFiles(flatEpisodes)))
        }
        return .series(BaiduPanSeriesStructure(seasons: seasons))
    }

    /// 分集排序:**按集号升序**,没有集号的排最后(按标题,给一个稳定顺序而不是随机的)。
    ///
    /// ⚠️ 不能只靠 `BaiduPanSortOrder` 那套文件名排序:集号是解析出来的语义值,
    /// `第10集` / `S01E10` 这类文件名按字符串排会把第 10 集排到第 2 集前面。
    static func sortedEpisodes(_ episodes: [SourceItem]) -> [SourceItem] {
        episodes.sorted { lhs, rhs in
            switch (lhs.episodeNumber, rhs.episodeNumber) {
            case let (left?, right?):
                return left == right ? lhs.title < rhs.title : left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.title < rhs.title
            }
        }
    }
}
