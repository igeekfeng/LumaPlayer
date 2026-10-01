import Foundation

/// 主窗口的媒体库入口(首页「我的媒体」与媒体库页共用)。
///
/// 入口列表来自服务器返回的 `/Users/{UserId}/Views`,**不写死**「电影/电视剧」
/// (UI_DESIGN.md 3.1:媒体库使用服务器返回的名称)。
///
/// 状态按服务器分开存(issue #3):切回加载过的服务器时直接显示上次的列表、后台刷新,
/// 首页也就不必等列表回来才开始加载。
@MainActor
@Observable
final class BrowseViewModel {
    private let container: AppContainer

    /// 键是 `ServerProfile.id`
    private var viewsByServer: [UUID: LoadState<[EmbyView]>] = [:]

    private var generation = 0
    private var task: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    /// 某台服务器的媒体库入口;没加载过(或没有选中服务器)是 `.idle`
    func viewsState(for serverID: UUID?) -> LoadState<[EmbyView]> {
        serverID.flatMap { viewsByServer[$0] } ?? .idle
    }

    /// 已有列表时不回退到 loading:新列表到达后原地替换,失败则保留旧列表
    /// (与 `HomeViewModel.load` 同一立场)。首次加载 / 上次失败才显示加载态。
    func loadViews(server: ServerProfile) {
        task?.cancel()
        generation += 1
        let myGeneration = generation
        let serverID = server.id
        if viewsState(for: serverID).value == nil {
            viewsByServer[serverID] = .loading
        }
        task = Task {
            do {
                let views = try await container.connection(for: server).userViews()
                guard myGeneration == generation else { return }
                viewsByServer[serverID] = .loaded(views)
            } catch let error as EmbyAPIError {
                guard myGeneration == generation else { return }
                if error == .cancelled { return }
                fail(serverID, LoadFailure(error))
            } catch {
                guard myGeneration == generation else { return }
                fail(serverID, LoadFailure(.transport(.unknown)))
            }
        }
    }

    private func fail(_ serverID: UUID, _ failure: LoadFailure) {
        if viewsState(for: serverID).value != nil { return }
        viewsByServer[serverID] = .failed(failure)
    }
}
