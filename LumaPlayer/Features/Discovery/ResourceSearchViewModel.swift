import Foundation

/// 「找资源」页的 ViewModel。
///
/// 与 `SearchViewModel`(搜当前 Emby 服务器)完全分开:那个搜的是服务端已有的内容,
/// 这个搜的是**网盘分享**,结果还没有进网盘。两个页面的动作也不同(转存 vs 播放),
/// ⛔ 不要为了省一个类型把它们合并 —— 合并后每个调用点都要判断「这是哪一种结果」。
@MainActor
@Observable
final class ResourceSearchViewModel {
    private let container: AppContainer

    /// 已提交的关键词(输入框按回车才变)
    private(set) var submittedKeyword = ""
    /// 结果状态。`nil` = 还没搜过
    private(set) var state: LoadState<PanResourceSearchResult>?
    /// 当前网盘类型筛选(`nil` = 全部)
    var cloudTypeFilter: PanCloudType?

    /// 搜索源清单快照(设置页改完由 `reloadSources()` 刷新)
    private(set) var sources: [ResourceSource] = []
    private(set) var sourcesLoadFailure: String?

    private var searchTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    var isLoading: Bool { state?.isLoading ?? false }

    /// 展示用的结果(已按网盘类型筛选)
    var visibleResources: [PanResource] {
        guard let result = state?.value else { return [] }
        return PanResourceSearchService.filter(result.resources, cloudType: cloudTypeFilter)
    }

    /// 结果里出现过的网盘类型(筛选器选项)
    var availableCloudTypes: [PanCloudType] {
        guard let result = state?.value else { return [] }
        return PanResourceSearchService.availableCloudTypes(in: result.resources)
    }

    /// 失败的源。⛔ 不隐藏:用户要知道「这次少搜了谁」。
    var failures: [PanResourceSourceFailure] {
        state?.value?.failures ?? []
    }

    /// 没配置任何搜索源 —— 引导去设置页,而不是显示一个空结果。
    var hasNoSources: Bool { sources.filter(\.isEnabled).isEmpty }

    func loadSources() async {
        sources = await container.resourceSources.sources()
        sourcesLoadFailure = await container.resourceSources.lastLoadFailureDescription()
    }

    /// 提交搜索。空关键词视为清空,不发请求。
    ///
    /// 上一次搜索还在跑就取消:连按两次回车不该让两个结果互相覆盖。
    func search(_ rawKeyword: String) {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchTask?.cancel()
            searchTask = nil
            state = nil
            submittedKeyword = ""
            return
        }
        searchTask?.cancel()
        submittedKeyword = keyword
        cloudTypeFilter = nil
        state = .loading
        let sources = self.sources
        searchTask = Task { [weak self] in
            guard let self else { return }
            let result = await container.resourceSearch.search(keyword: keyword, sources: sources)
            guard !Task.isCancelled else { return }
            self.state = .loaded(result)
        }
    }

    /// 重新搜索当前关键词(重试 / 设置页改完源之后)
    func retry() {
        guard !submittedKeyword.isEmpty else { return }
        search(submittedKeyword)
    }
}
