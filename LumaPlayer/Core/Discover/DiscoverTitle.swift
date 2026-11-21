import Foundation

/// 「看什么」页的一张卡。**与数据源无关**:豆瓣和 TMDB 都翻成这个形状,视图只认它。
///
/// 为什么要有这一层:榜单来源会换(豆瓣的未公开接口随时可能失效),但「画一张卡」和
/// 「点一下去搜资源」这两件事不该跟着换。数据源之间的差异在各自的 provider 里吃掉。
struct DiscoverTitle: Sendable, Equatable, Identifiable {

    /// 全局唯一:`"douban:36689621"` / `"tmdb:movie:1399"`。同时当图片缓存 key 的版本段。
    let id: String
    let title: String
    let year: Int?
    /// 10 分制;nil = 还没有评分(豆瓣给正在上映的片子就是 `rating: null`)
    let rating: Double?
    let overview: String?
    /// 豆瓣的 `card_subtitle` 原文:`2026 / 中国大陆 / 剧情 古装 / 张黎 安巍 / 成毅 林更新`。
    /// TMDB 没有对应字段,给 nil。⛔ 不自己拼:分段的含义只有豆瓣知道。
    let cardSubtitle: String?
    /// 剧集更新进度(`episodes_info`:`更新至12集` / `24集全`)。
    /// ⚠️ 这个字段**可能很长**(个别条目带整段排播说明),映射时就按 `episodesInfoMaxLength` 截断。
    let episodesInfo: String?
    let poster: Poster?

    /// 海报地址 + 取图所需的请求头。豆瓣图床有防盗链,不带 `Referer` 会回 418。
    struct Poster: Sendable, Equatable {
        let url: URL
        let headers: [String: String]
    }

    /// 副标题:「2026 · 8.6 分」。缺哪段就少哪段,⛔ 不补占位。
    var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let rating, rating > 0 { parts.append(String(format: "%.1f 分", rating)) }
        return parts.joined(separator: " · ")
    }

    /// 卡片上的更新进度行。豆瓣这个字段**没有长度上限**(实测多数是「更新至12集」这种六个字,
    /// 但个别条目会塞一整段排播说明),卡片只有一行位置:先按字数截断,再交给 `.lineLimit(1)`
    /// 兜住字体 / 宽度差异。⛔ 不做成「按像素切」—— 那会停在半个词上。
    var episodesInfoLine: String? {
        guard let raw = episodesInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard raw.count > Self.episodesInfoMaxLength else { return raw }
        return String(raw.prefix(Self.episodesInfoMaxLength)) + "…"
    }

    /// 更新进度行的字数上限。只影响卡片显示,`episodesInfo` 原值照旧留着(`.help` 里给全文)。
    static let episodesInfoMaxLength = 14

    /// 资源搜索用的关键词:中文标题。
    ///
    /// ⛔ 不拼年份:多数搜索源不认「片名 2026」这种写法,拼了反而搜不到。
    var searchKeyword: String { title }

    var posterDescriptor: ImageDescriptor? {
        guard let poster else { return nil }
        return .remote(
            ownerID: Self.imageOwner,
            url: poster.url,
            headers: poster.headers,
            cacheKey: "\(id)-poster")
    }

    /// 图片缓存分区:发现页的图不跟随任何来源,单独一个固定 id。
    private static let imageOwner = UUID(uuidString: "00000000-0000-0000-0000-0000000D1500")!
}

/// 豆瓣图床的防盗链绕过:裸请求回 418(14 字节占位),带任一豆瓣站点的 `Referer` 才给真图。
enum DoubanImageHeaders {
    static let referer = "https://movie.douban.com/"
    static let headers = ["Referer": referer]
}
