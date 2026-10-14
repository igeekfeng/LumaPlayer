import Foundation

/// 「把这一整个剧集目录改成标准 TMDB 命名」这条流程的编排者。
///
/// ## 四步,每一步都可能停下来等人
///
/// ```
/// 列目录树 → 认剧(有 id 直取 / 没 id 搜索后请你选) → 生成计划(预览) → 提交
/// ```
///
/// ⛔ **不自动替你认剧**。目录名没写 `{tmdbid-N}` 时只能按标题搜,而同名剧可能有好几部
/// (`一拳超人` 就不止一条)。搜出来多条就列给你选,**只有一条也让你点一下确认** ——
/// 选错剧的代价是整个目录按错的剧改名,那比不改还糟(CLAUDE.md 硬规则 4)。
///
/// ## 网络与配额
///
/// 一次流程要发:1 次列剧目录 + N 次列季目录 + (0~1 次搜索) + N 次季详情 + 若干次提交。
/// ⛔ 前两类走**百度配额(见 §7)**,TMDB 那几类不走,所以 UI 里
/// `submittedBatches` 之外还要把「列目录用了几次」说出来 —— 让用户知道自己在花什么。
@MainActor
@Observable
final class BaiduPanRenameSeriesViewModel {

    /// 流程走到哪一步。UI 按它决定显示什么。
    enum Stage: Sendable, Equatable {
        case idle
        /// 正在列目录 / 问 TMDB
        case preparing(String)
        /// 搜出多条候选,等用户认剧
        case choosingSeries
        /// 计划出来了,等用户确认
        case preview
        case executing
        case finished
    }

    private let container: AppContainer
    private let client = TMDBClient()

    private(set) var stage: Stage = .idle
    private(set) var isBusy = false
    private(set) var failure: String?

    /// 认剧阶段的候选(含剧名 / 首播年 / 海报路径)。
    private(set) var candidates: [TMDBMatch] = []
    private(set) var selectedSeries: TMDBMatch?

    private(set) var plan: BaiduPanRenamePlanner.Plan?
    private(set) var outcome: BaiduPanRenameExecutor.Outcome?

    /// 列目录用掉几次百度请求(配额口径)。
    private(set) var listingRequests = 0

    /// 提交这次计划要发几次请求(配额口径,给用户看的预计值)。
    var plannedBatchCount: Int {
        guard let plan else { return 0 }
        let pending = plan.items.filter { !$0.isUnchanged }
        return BaiduPanRenameExecutor.batches(
            of: pending, batchLimit: BaiduPanRenameExecutor.defaultBatchLimit).count
    }

    private var root: BaiduPanFile?
    private var tree: [BaiduPanFile] = []
    private var token: String?

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: - 第一步:列目录 + 认剧

    /// 从用户选中的剧目录开始。
    func start(directory: BaiduPanFile) async {
        root = directory
        isBusy = true
        failure = nil
        defer { isBusy = false }
        stage = .preparing("正在读取目录…")
        listingRequests = 0

        do {
            let readToken = try await tmdbToken()
            token = readToken
            let entries = try await loadTree(root: directory)
            tree = entries

            // 目录名里写了权威 id 就不用问了
            if let explicit = BaiduPanMetadataSynthesizer
                .extractExplicitTMDBID(in: directory.name)?.id {
                stage = .preparing("正在取剧的信息…")
                let match = try await client.details(
                    id: explicit, isSeries: true, token: readToken)
                try await apply(series: match)
                return
            }

            stage = .preparing("正在搜索…")
            let matches = try await client.search(
                title: directory.name, year: nil, isSeries: true, token: readToken)
            guard !matches.isEmpty else {
                failure = "TMDB 上搜不到「\(directory.name)」,改不了名。可以在网盘里把目录名写得更明确一点再试。"
                stage = .idle
                return
            }
            candidates = matches
            stage = .choosingSeries
        } catch {
            failure = Self.describe(error)
            stage = .idle
        }
    }

    /// 递归列两层:剧目录 → 季目录里的文件。
    ///
    /// ⚠️ 只列两层(剧 / 季 / 文件)。更深的嵌套不是标准库的形状,列下去只会多烧配额;
    /// 而配额见 `BAIDU_PAN_API.md` §7。
    private func loadTree(root: BaiduPanFile) async throws -> [BaiduPanFile] {
        let connection = container.baiduConnection()
        let topLevel = try await connection.files(inDirectory: root.path)
        listingRequests += 1
        var entries: [BaiduPanFile] = [root] + topLevel
        for child in topLevel where child.isDirectory {
            entries.append(contentsOf: try await connection.files(inDirectory: child.path))
            listingRequests += 1
        }
        return entries
    }

    // MARK: - 第二步:认剧后生成计划

    /// 用户选定是哪部剧。
    func choose(_ match: TMDBMatch) async {
        selectedSeries = match
        isBusy = true
        failure = nil
        defer { isBusy = false }
        stage = .preparing("正在取分集信息…")
        do {
            try await apply(series: match)
        } catch {
            failure = Self.describe(error)
            stage = .choosingSeries
        }
    }

    private func apply(series: TMDBMatch) async throws {
        guard let root, let readToken = token else { return }
        selectedSeries = series
        // ⚠️ 问哪几季必须与 `makePlan` 的判据一致:平铺存法(剧根下直接是集文件)
        // 在那边按第 1 季处理,这里就得把第 1 季的分集表取回来,否则集标题全丢。
        let seasons = BaiduPanRenamePlanner.seasonNumbers(in: tree, root: root)
        var titles: [Int: [Int: String]] = [:]
        for season in seasons {
            let episodes = try await client.seasonDetails(
                seriesID: series.tmdbID, seasonNumber: season, token: readToken)
            var table: [Int: String] = [:]
            for episode in episodes {
                // 空串当「没有集名」(TMDB 偶尔给 `""`),⛔ 不用它顶一个假标题
                if let name = episode.name, !name.isEmpty { table[episode.episodeNumber] = name }
            }
            titles[season] = table
        }

        let identity = BaiduPanRenamePlanner.SeriesIdentity(
            tmdbID: series.tmdbID,
            // TMDB 没给标题时退回目录名(剥掉 `{tmdbid-}` 标签),⛔ 不留空
            title: series.title ?? fallbackSeriesTitle,
            year: series.year)
        plan = BaiduPanRenamePlanner.makePlan(
            root: root, entries: tree, identity: identity, episodeTitles: titles)
        stage = .preview
    }

    private var fallbackSeriesTitle: String {
        guard let root else { return "" }
        return BaiduPanMetadataSynthesizer.extractExplicitTMDBID(in: root.name)?.cleaned
            .trimmingCharacters(in: .whitespaces) ?? root.name
    }

    // MARK: - 第三步:提交

    func execute() async {
        guard let plan else { return }
        isBusy = true
        failure = nil
        defer { isBusy = false }
        stage = .executing
        let connection = container.baiduConnection()
        let result = await BaiduPanRenameExecutor.run(plan: plan) { operations in
            try await connection.rename(operations)
        }
        outcome = result
        await applyLocalSideEffects(result)
        stage = .finished
    }

    /// 改名后同步本地快照。
    ///
    /// ⚠️ 进度本身按 `fs_id` 存,**不会丢**;但「续播卡片」用的展示快照里存的是
    /// `path` 与文件名(`WatchProgressStore.Display.locator`),那两个会失效 ——
    /// 不更新的话卡片还在、点下去却定位不到文件。
    private func applyLocalSideEffects(_ result: BaiduPanRenameExecutor.Outcome) async {
        for item in result.succeeded {
            await container.watchProgress.relocate(
                fileID: String(item.fsID),
                path: item.renamedPath,
                fileName: item.newName)
        }
    }

    // MARK: - 撤销

    /// 把这次已经改成功的部分改回原名。
    ///
    /// ⚠️ 只能撤销**已确认成功**的那部分 —— 执行器「失败即停」正是为了让这份清单算得出来。
    func rollback() async {
        guard let result = outcome, !result.succeeded.isEmpty else { return }
        isBusy = true
        failure = nil
        defer { isBusy = false }
        let operations = BaiduPanRenameExecutor.rollbackOperations(for: result)
        do {
            _ = try await container.baiduConnection().rename(operations)
            outcome = nil
            plan = nil
            stage = .idle
        } catch {
            failure = Self.describe(error)
        }
    }

    // MARK: - 小工具

    func dismissFailure() { failure = nil }

    private func tmdbToken() async throws -> String {
        guard let stored = try await container.credentials.tmdbReadAccessToken(),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BaiduPanError.configuration(
                "还没填 TMDB 的 Read Access Token:设置 → 元数据里填一下,改名要靠它取集名与首播年。")
        }
        return stored
    }

    private static func describe(_ error: any Error) -> String {
        if let tmdb = error as? TMDBError { return tmdb.userMessage }
        if let baidu = error as? BaiduPanError { return baidu.userMessage }
        return "\(error)"
    }
}
