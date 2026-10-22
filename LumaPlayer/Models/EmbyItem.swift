import Foundation

/// Emby 媒体项(BaseItemDto,API_CONTRACT.md 3.4 / 第 10 节)。
/// 只有 `Id` 与 `Name` 必填(8.1),其余缺失即 nil,⛔ 不填假默认值。
struct EmbyItem: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// `Movie` / `Series` / `Season` / `Episode` / ...
    let type: String?
    let overview: String?
    let productionYear: Int?
    /// 只用于列表 / 详情页粗略展示;播放时长以 MediaSource.RunTimeTicks 为准(API_CONTRACT.md 4.3)。
    let runTimeTicks: Int64?
    /// 集号
    let indexNumber: Int?
    /// 季号
    let parentIndexNumber: Int?
    let seasonID: String?
    let seriesID: String?
    let seriesName: String?
    let seasonName: String?
    let genres: [String]?
    let communityRating: Double?
    let officialRating: String?
    /// 如 `{"Primary": "abc"}`
    let imageTags: [String: String]?
    /// 官方 OpenAPI 里没有(只有 `ImageTags`),但 API_CONTRACT.md 3.3 标 ✅;两个都解,任一有值算有图(Q13)。
    let primaryImageTag: String?
    let backdropImageTags: [String]?
    /// 没有自己的 backdrop / logo / thumb 时用父级 Id 请求(API_CONTRACT.md 3.3)
    let parentBackdropItemID: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemID: String?
    let parentLogoImageTag: String?
    let parentThumbItemID: String?
    let parentThumbImageTag: String?
    /// `var`:标记已看、收藏成功后用服务端返回的新 UserData 就地替换(API_CONTRACT.md 5.5/5.6)。
    var userData: EmbyUserData?

    // MARK: 详情页字段(API_CONTRACT.md 3.4)
    //
    // 单项接口默认返回;列表接口要显式 `Fields` 才有。

    let people: [EmbyPerson]?
    let studios: [EmbyStudio]?
    let taglines: [String]?
    /// ISO 8601 原文,只用于展示年月日
    let premiereDate: String?
    /// 剧集的季数
    let childCount: Int?
    let criticRating: Double?
    /// 只给详情页「媒体信息」;播放用的轨道以 PlaybackInfo 的 MediaSource 为准(4.3)
    let mediaStreams: [EmbyMediaStream]?
    /// 外部元数据 id(`Tmdb` / `Tvdb` / `Imdb` …)。列表接口要 `Fields=ProviderIds` 才返回(API_CONTRACT.md 3.2);
    /// 键名大小写不统一,按小写比较。`var` + 默认值只为让逐成员构造器可省略它。
    var providerIds: [String: String]? = nil

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
        case providerIds = "ProviderIds"
    }
}

/// `BaseItemPerson`
struct EmbyPerson: Decodable, Sendable, Equatable, Identifiable {
    /// 头像走 `/Items/{Id}/Images/Primary`(API_CONTRACT.md 3.3)
    let id: String
    let name: String
    /// 饰演的角色或职务说明
    let role: String?
    /// `Actor` / `Director` / `Writer` / `GuestStar` …(自由字符串,不枚举)
    let type: String?
    /// 有值才请求头像
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

/// 制片公司(`NameLongIdPair`)。只解 `Name`:`Id` 类型在各版本未核实,解它可能让整项详情解码失败。
struct EmbyStudio: Decodable, Sendable, Equatable {
    let name: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

/// `UserItemDataDto`
struct EmbyUserData: Decodable, Sendable, Equatable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let playedPercentage: Double?
    let playCount: Int?
    let isFavorite: Bool?
    /// 剧集 / 季里还有几集没看
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
    /// 其他值或缺失一律 `.other`,不猜、不报错。
    var kind: EmbyItemKind {
        switch type {
        case "Movie": return .movie
        case "Series": return .series
        case "Season": return .season
        case "Episode": return .episode
        default: return .other
        }
    }

    /// 没有就不请求图片(会 404,API_CONTRACT.md 3.3)。
    var primaryImageTagValue: String? {
        imageTags?["Primary"] ?? primaryImageTag
    }

    /// 优先自己,没有则回退父级(须带 tag)。
    var backdropSource: (itemID: String, tag: String)? {
        if let tag = backdropImageTags?.first {
            return (id, tag)
        }
        if let parentID = parentBackdropItemID, let tag = parentBackdropImageTags?.first {
            return (parentID, tag)
        }
        return nil
    }

    /// 优先自己,没有则回退父级。
    var logoSource: (itemID: String, tag: String)? {
        if let tag = imageTags?["Logo"] {
            return (id, tag)
        }
        if let parentID = parentLogoItemID, let tag = parentLogoImageTag {
            return (parentID, tag)
        }
        return nil
    }

    /// 横版(16:9)图。分集的 `Primary` 就是剧照,优先用它;其余依次取
    /// 自己的 Thumb → Backdrop → 父级 Thumb → 父级 Backdrop,每级都要求 tag 存在。
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

    /// 「继续观看 / 下一集」卡片封面:优先横版,没有就退回自己的竖版海报(居中裁切,Q35)。
    /// Resume 里的电影条目常常只有 `Primary`、`BackdropImageTags` 为空,不退回就只剩占位图。
    var coverImage: (itemID: String, type: EmbyImageType, tag: String)? {
        if let landscape = landscapeImage { return landscape }
        if let tag = primaryImageTagValue { return (id, .primary, tag) }
        return nil
    }

    /// `coverImage` 的失败退路:同一项的竖版海报;首选已是海报或没有海报时为 nil。
    /// 有的服务器在 `BackdropImageTags` 里回填 `Primary` 的 tag,而请求 Backdrop 直接 404。
    var coverImageFallback: (itemID: String, type: EmbyImageType, tag: String)? {
        guard coverImage?.type != .primary, let tag = primaryImageTagValue else { return nil }
        return (id, .primary, tag)
    }

    var isPlayed: Bool { userData?.played ?? false }
    var isFavorite: Bool { userData?.isFavorite ?? false }

    /// `ProviderIds.Tmdb`,键名按小写比较。值不是正整数返回 nil(⛔ 不把脏数据当 id 发出去)。
    var tmdbID: Int? {
        guard let raw = providerIds?.first(where: { $0.key.lowercased() == "tmdb" })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = Int(raw), value > 0
        else { return nil }
        return value
    }

    /// 0–1;缺时长或没看过返回 nil。直接算比例,不引入 ticks 换算常量。
    var progressFraction: Double? {
        guard let runtime = runTimeTicks, runtime > 0,
              let position = userData?.playbackPositionTicks, position > 0 else {
            return nil
        }
        return min(1, Double(position) / Double(runtime))
    }

    /// 「S1E2」,只对 Episode 有值;缺一个显示有的那个,都缺返回 nil。
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

/// 只为 UI 分支服务,不是 `Type` 的全集。
enum EmbyItemKind: Sendable, Equatable {
    case movie
    case series
    case season
    case episode
    /// 不在上述四种里或缺失
    case other
}
