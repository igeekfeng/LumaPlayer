import Foundation

/// Emby 的媒体项(BaseItem,术语见 API_CONTRACT.md 第 10 节)。
///
/// 字段按 `API_CONTRACT.md` 8.1 的可选性原则:**只有 `Id` 与 `Name` 必填**,
/// 其余一律可选、缺失即 nil,⛔ 不填假默认值(「未知」「0」都不行)。
///
/// 字段名来源:2026-09-22 对官方 OpenAPI(swagger.emby.media,4.1.1.0)
/// 的 BaseItemDto / UserItemDataDto 核实,见 API_CONTRACT.md 3.4。
struct EmbyItem: Decodable, Sendable, Equatable, Identifiable {
    /// 必填(API_CONTRACT.md 8.1)
    let id: String
    /// 必填(API_CONTRACT.md 8.1)
    let name: String
    /// `Movie` / `Series` / `Season` / `Episode` / ...(第 10 节术语表)
    let type: String?
    let overview: String?
    let productionYear: Int?
    /// 时长(ticks)。⚠️ **播放时长以 MediaSource.RunTimeTicks 为准**
    /// (API_CONTRACT.md 4.3),这里的值只用于列表/详情页的粗略展示。
    let runTimeTicks: Int64?
    /// 集号(Episode)
    let indexNumber: Int?
    /// 季号(Episode)
    let parentIndexNumber: Int?
    let seasonID: String?
    let seriesID: String?
    let seriesName: String?
    let seasonName: String?
    let genres: [String]?
    let communityRating: Double?
    let officialRating: String?
    /// 本项自己的图片 tag 集合,如 `{"Primary": "abc"}`
    let imageTags: [String: String]?
    /// `Primary` 图片的 tag。官方 4.1.1.0 OpenAPI 的 BaseItemDto 里没有这个字段
    /// (只有 `ImageTags`),但 `API_CONTRACT.md` 3.3 以它为例且标 ✅;
    /// 两个都解,取到的任意一个都算「有图」(见 docs/KNOWN_ISSUES.md Q13)。
    let primaryImageTag: String?
    let backdropImageTags: [String]?
    /// 图片可从父级继承(API_CONTRACT.md 3.3):没有 backdrop/logo 时用父级 Id 请求
    let parentBackdropItemID: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemID: String?
    let parentLogoImageTag: String?
    let parentThumbItemID: String?
    let parentThumbImageTag: String?
    /// 播放进度 / 已看 / 收藏;服务器未返回就是 nil。
    /// `var`:标记已看、收藏成功后用服务端返回的新 UserData 就地替换(API_CONTRACT.md 5.5/5.6)。
    var userData: EmbyUserData?

    // MARK: 详情页字段(API_CONTRACT.md 3.4「详情页字段」)
    //
    // 单项接口默认返回;列表接口要显式 `Fields` 才有。

    /// 演职人员
    let people: [EmbyPerson]?
    /// 制片公司(只解 `Name`,见 `EmbyStudio`)
    let studios: [EmbyStudio]?
    let taglines: [String]?
    /// 首映 / 首播日期(ISO 8601 原文;只用于展示年月日,不参与计算)
    let premiereDate: String?
    /// 剧集的季数(Series)
    let childCount: Int?
    let criticRating: Double?
    /// 详情页「媒体信息」用;⚠️ 播放用的轨道仍以 PlaybackInfo 的 MediaSource 为准(4.3)
    let mediaStreams: [EmbyMediaStream]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seasonID = "SeasonId"
        case seriesID = "SeriesId"
        case seriesName = "SeriesName"
        case seasonName = "SeasonName"
        case genres = "Genres"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case imageTags = "ImageTags"
        case primaryImageTag = "PrimaryImageTag"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemID = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case parentThumbItemID = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case userData = "UserData"
        case people = "People"
        case studios = "Studios"
        case taglines = "Taglines"
        case premiereDate = "PremiereDate"
        case childCount = "ChildCount"
        case criticRating = "CriticRating"
        case mediaStreams = "MediaStreams"
    }
}

/// 演职人员(`BaseItemPerson`,官方 OpenAPI 4.1.1.0 核实 2026-09-23)。
struct EmbyPerson: Decodable, Sendable, Equatable, Identifiable {
    /// 人物条目 Id;头像走 `/Items/{Id}/Images/Primary`(API_CONTRACT.md 3.3)
    let id: String
    let name: String
    /// 饰演的角色(演员)或职务说明
    let role: String?
    /// `Actor` / `Director` / `Writer` / `GuestStar` …(自由字符串,不枚举)
    let type: String?
    /// 有值才请求头像(没有 tag 去请求只会 404)
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

/// 制片公司(`NameLongIdPair`)。只解 `Name`:4.1.1.0 规格里 `Id` 是 int64,
/// 其他版本的类型未核实,解它有让整项详情解码失败的风险,而界面用不到它。
struct EmbyStudio: Decodable, Sendable, Equatable {
    let name: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

/// 用户对某一项的播放数据(UserItemDataDto,官方 OpenAPI 核实 2026-09-22)。
struct EmbyUserData: Decodable, Sendable, Equatable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let playedPercentage: Double?
    let playCount: Int?
    let isFavorite: Bool?
    /// 剧集 / 季里还有几集没看(海报角标用)
    let unplayedItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case playedPercentage = "PlayedPercentage"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case unplayedItemCount = "UnplayedItemCount"
    }
}

extension EmbyItem {
    /// Item 的 `Type` 归类(API_CONTRACT.md 第 10 节:Movie / Series / Season / Episode)。
    ///
    /// 服务器返回别的值(或没有 Type)一律是 `.other`:不猜、不报错,
    /// 由 UI 决定怎么展示。
    var kind: EmbyItemKind {
        switch type {
        case "Movie": return .movie
        case "Series": return .series
        case "Season": return .season
        case "Episode": return .episode
        default: return .other
        }
    }

    /// `Primary` 图片的 tag;没有就不请求图片(否则会 404,API_CONTRACT.md 3.3)。
    var primaryImageTagValue: String? {
        imageTags?["Primary"] ?? primaryImageTag
    }

    /// 可请求 Backdrop 的 Item Id:优先自己,没有则回退父级(API_CONTRACT.md 3.3)。
    /// 只在父级确实带 backdrop tag 时才回退。
    var backdropSource: (itemID: String, tag: String)? {
        if let tag = backdropImageTags?.first {
            return (id, tag)
        }
        if let parentID = parentBackdropItemID, let tag = parentBackdropImageTags?.first {
            return (parentID, tag)
        }
        return nil
    }

    /// 可请求 Logo 的 Item Id:优先自己,没有则回退父级(API_CONTRACT.md 3.3)。
    var logoSource: (itemID: String, tag: String)? {
        if let tag = imageTags?["Logo"] {
            return (id, tag)
        }
        if let parentID = parentLogoItemID, let tag = parentLogoImageTag {
            return (parentID, tag)
        }
        return nil
    }

    /// 横版(16:9)图:「继续观看」卡片与分集行用。
    ///
    /// 分集自己的 `Primary` 就是剧照截图,优先用它;其余类型依次取
    /// 自己的 Thumb → 自己的 Backdrop → 父级 Thumb → 父级 Backdrop。
    /// 每一级都要求对应 tag 存在才返回(没 tag 去请求只会 404,3.3)。
    var landscapeImage: (itemID: String, type: EmbyImageType, tag: String)? {
        if kind == .episode, let tag = primaryImageTagValue {
            return (id, .primary, tag)
        }
        if let tag = imageTags?["Thumb"] {
            return (id, .thumb, tag)
        }
        if let tag = backdropImageTags?.first {
            return (id, .backdrop, tag)
        }
        if let parentID = parentThumbItemID, let tag = parentThumbImageTag {
            return (parentID, .thumb, tag)
        }
        if let parentID = parentBackdropItemID, let tag = parentBackdropImageTags?.first {
            return (parentID, .backdrop, tag)
        }
        return nil
    }

    var isPlayed: Bool { userData?.played ?? false }
    var isFavorite: Bool { userData?.isFavorite ?? false }

    /// 播放进度 0–1;缺时长或没看过时返回 nil(UI 据此决定画不画进度条)。
    ///
    /// 用「位置 / 时长」直接算比例,不引入 ticks 换算常量
    /// (ticks ↔ 秒的换算统一走 `TickConverter`)。
    var progressFraction: Double? {
        guard let runtime = runTimeTicks, runtime > 0,
              let position = userData?.playbackPositionTicks, position > 0 else {
            return nil
        }
        return min(1, Double(position) / Double(runtime))
    }

    /// 「S1E2」这样的集标识,只对 Episode 有值。季号 / 集号都来自服务端字段,
    /// 缺一个就只显示有的那个;两个都缺返回 nil(不填占位符)。
    var episodeLabel: String? {
        guard kind == .episode else { return nil }
        switch (parentIndexNumber, indexNumber) {
        case let (season?, episode?): return "S\(season)E\(episode)"
        case let (season?, nil): return "第 \(season) 季"
        case let (nil, episode?): return "第 \(episode) 集"
        case (nil, nil): return nil
        }
    }
}

/// Item 的类型归类(只为 UI 分支服务;不是对 `Type` 的全集枚举)。
enum EmbyItemKind: Sendable, Equatable {
    case movie
    case series
    case season
    case episode
    /// 服务器返回的 Type 不在上述四种里(或缺失)
    case other
}
