import Foundation

/// 目录的内容形态:普通目录(继续网格浏览)还是一部剧(进剧集详情页)。
///
/// 百度只有目录树,剧 / 季结构靠用户的存法表达:
///
/// ```
/// 琅琊榜/01.mp4、02.mp4、…            剧目录下直接摆集文件 = 第 1 季
/// 琅琊榜/第1季/01.mp4、第2季/…        剧目录下是季文件夹 = 一层一季
/// ```
enum BaiduPanDirectoryShape: Equatable, Sendable {
    case directory
    case series(BaiduPanSeriesStructure)

    var seriesStructure: BaiduPanSeriesStructure? {
        if case .series(let structure) = self { return structure }
        return nil
    }

    var isSeries: Bool { seriesStructure != nil }
}

struct BaiduPanSeriesStructure: Equatable, Sendable {
    /// 有季号的按季号升序,「未分季」排最后。至少一季。
    let seasons: [BaiduPanSeason]

    /// 只有一季时详情页不显示季选择器
    var isSingleSeason: Bool { seasons.count <= 1 }
}

struct BaiduPanSeason: Equatable, Sendable, Identifiable {
    /// `nil` = 未分季:剧目录里既有季文件夹又有平铺集文件时,平铺的那批单列一季,不丢掉(`CLAUDE.md` 硬规则 4)。
    let number: Int?
    /// `第 N 季` / `特别篇`(第 0 季)/ `未分季`
    let title: String
    let source: Source

    /// 两种载体请求代价不同:季文件夹要另外列一次目录(百度配额,`docs/BAIDU_PAN_API.md` §7);
    /// 平铺集文件列剧目录时已拿到。
    enum Source: Equatable, Sendable {
        case folder(SourceItem)
        case flatFiles([SourceItem])
    }

    var id: String {
        number.map(String.init) ?? Self.unassignedID
    }

    static let unassignedID = "unassigned"

    /// 第 0 季是 TMDB 口径的特别篇(`docs/TMDB_API.md` §7),不是「没解析出来」。
    static func title(forSeason number: Int?) -> String {
        guard let number else { return "未分季" }
        return number == 0 ? "特别篇" : "第 \(number) 季"
    }
}

/// 目录形态判定(纯函数)。只看合成后的 `[SourceItem]`,季号 / 集号来自 `BaiduPanMetadataSynthesizer`。
enum BaiduPanSeriesLayout {

    /// 判据(按优先级;⛔ 不放宽,认不出就当普通目录):
    ///
    /// 1. 有季文件夹(整个目录名就是季标记,`seasonNumber(fromDirectoryName:)`;`琅琊榜 第13季` 这种不认)→ 各季。
    /// 2. 否则这一层有 `.episode` 条目 → 第 1 季。可靠是因为合成器已用「同目录 ≥2 个集号型文件名」
    ///    排除了平铺的电影(`looksLikeEpisodeSequence`)。
    ///
    /// 都不满足 → `.directory`。⛔ 不能无条件当剧:「电影」「纪录片」这类分类目录下全是子目录,会整库误判。
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
        // 季文件夹与平铺文件并存:平铺的那批单列一季
        if !flatEpisodes.isEmpty {
            seasons.append(BaiduPanSeason(
                number: nil,
                title: BaiduPanSeason.title(forSeason: nil),
                source: .flatFiles(flatEpisodes)))
        }
        return .series(BaiduPanSeriesStructure(seasons: seasons))
    }

    /// 按集号升序,无集号的按标题排最后。⛔ 不用 `BaiduPanSortOrder` 的文件名排序:`第10集` 会排到 `第2集` 前面。
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
