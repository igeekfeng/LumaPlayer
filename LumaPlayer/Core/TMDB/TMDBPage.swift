import Foundation

/// TMDB **站点页面**地址(`www.themoviedb.org`,不是 `api.` / `image.` 两个主机)。
///
/// 只用于「在 TMDB 上打开这一部」的浏览器跳转,⛔ 不发请求、不带 token(`docs/TMDB_API.md` §13)。
/// 界面语言走 `?language=`,⛔ 不是路径里的 `/zh-CN/` 段 —— 后者实测 404。
enum TMDBPage {
    static let host = "www.themoviedb.org"

    static func movieURL(id: Int) -> URL? { url(path: "/movie/\(id)") }

    static func seriesURL(id: Int) -> URL? { url(path: "/tv/\(id)") }

    private static func url(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "language", value: TMDBClient.defaultLanguage)]
        return components.url
    }
}

extension TMDBMatch {
    /// 电影 → `/movie/{id}`,剧 → `/tv/{id}`。
    var tmdbPageURL: URL? {
        switch kind {
        case .movie: return TMDBPage.movieURL(id: tmdbID)
        case .tv: return TMDBPage.seriesURL(id: tmdbID)
        }
    }
}

extension EmbyItem {
    /// 只给**电影 / 剧集**的剧级条目。
    ///
    /// ⚠️ 分集不带:分集的 `ProviderIds.Tmdb` 是**单集** id,站点地址要的是剧级 id,
    /// 拼接口径对不上(`docs/API_CONTRACT.md` §3.4),⛔ 拿它拼一个错页面。
    var tmdbPageURL: URL? {
        guard let tmdbID else { return nil }
        switch kind {
        case .movie: return TMDBPage.movieURL(id: tmdbID)
        case .series: return TMDBPage.seriesURL(id: tmdbID)
        default: return nil
        }
    }
}
