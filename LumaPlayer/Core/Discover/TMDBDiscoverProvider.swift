import Foundation

/// TMDB 榜单。要 v4 Read Access Token;没配就是「不可用」,而不是空榜单。
///
/// 端点事实见 `docs/DISCOVERY.md` §3.1 / §3.2,解码复用 `Core/TMDB/`。
struct TMDBDiscoverProvider: DiscoverProvider {
    let kind: DiscoverSourceKind = .tmdb

    private let client: TMDBClient
    /// token 用时才取:设置页刚填就生效,⛔ 不在构造时缓存
    private let credentials: CredentialStore

    init(client: TMDBClient, credentials: CredentialStore) {
        self.client = client
        self.credentials = credentials
    }

    static let builtInBoards: [DiscoverBoard] = [
        DiscoverBoard(source: .tmdb, reference: "trending", title: "本周热门"),
        DiscoverBoard(source: .tmdb, reference: "movieHot", title: "热门电影"),
        DiscoverBoard(source: .tmdb, reference: "tvHot", title: "热门剧集"),
    ]

    var boards: [DiscoverBoard] { Self.builtInBoards }

    func availability() async -> DiscoverUnavailable? {
        guard let token = try? await credentials.tmdbReadAccessToken(),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return DiscoverUnavailable(
                source: .tmdb,
                message: "填一个 TMDB v4 Read Access Token 就能用(设置 → 通用)。",
                needsToken: true)
        }
        return nil
    }

    func load(_ board: DiscoverBoard, page: Int) async throws -> DiscoverPage {
        guard board.source == .tmdb else {
            throw DiscoverError.unsupportedBoard(board.id)
        }
        guard let token = try await credentials.tmdbReadAccessToken(),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DiscoverError.unsupportedBoard(board.id)
        }
        // TMDB 的 page 是 1 起,榜单层统一用 0 起
        let apiPage = max(0, page) + 1

        do {
            let response: TMDBDiscoverPage
            switch board.reference {
            case "trending":
                response = try await client.trending(
                    mediaType: .all, window: .week, page: apiPage, token: token)
            case "movieHot":
                var query = TMDBDiscoverQuery()
                query.sortBy = .popularity
                query.page = apiPage
                response = try await client.discoverMovie(query: query, token: token)
            case "tvHot":
                var query = TMDBDiscoverQuery()
                query.sortBy = .popularity
                query.page = apiPage
                response = try await client.discoverTV(query: query, token: token)
            default:
                throw DiscoverError.unsupportedBoard(board.id)
            }
            return DiscoverPage(
                items: response.items.compactMap(Self.title(from:)),
                // 以 TMDB 自己给的 `total_pages` 为准,⛔ 不用「本页装满没」推断
                hasMore: response.hasMore)
        } catch let error as TMDBError {
            throw Self.discoverError(error)
        }
    }

    /// 把 TMDB 的错误折成榜单层能展示的形状。`userMessage` 已经是中文,直接用。
    static func discoverError(_ error: TMDBError) -> DiscoverError {
        switch error {
        case .transport(let detail): return .transport(detail)
        case .decoding(let detail): return .decoding(detail)
        case .server(let statusCode, let message): return .http(statusCode: statusCode, message: message)
        case .rateLimited: return .http(statusCode: 429, message: nil)
        case .notFound, .unauthorized, .tokenMissing:
            // 这三种在榜单场景下只会是配置问题,`availability()` 已经先拦了一道
            return .http(statusCode: 401, message: nil)
        }
    }

    /// TMDB 的条目 → 页面模型。⛔ 没有标题的条目丢掉:卡片没标题等于不可用。
    static func title(from match: TMDBMatch) -> DiscoverTitle? {
        guard let name = match.title, !name.isEmpty else { return nil }
        let poster = match.posterURL.map { DiscoverTitle.Poster(url: $0, headers: [:]) }
        return DiscoverTitle(
            id: "tmdb:\(match.kind.rawValue):\(match.tmdbID)",
            title: name,
            year: match.year,
            rating: match.voteAverage,
            overview: match.overview,
            // TMDB 没有 `card_subtitle` / `episodes_info`:⛔ 不拿 overview 或季集数冒充
            cardSubtitle: nil,
            episodesInfo: nil,
            poster: poster)
    }
}
