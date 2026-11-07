import Foundation

/// 网盘 / 本地来源页的 `FileSourceViewModel`,按来源 id 各留一份,由 `BrowseView` 持有。
///
/// 来源页按来源 id 重建视图(见 `BrowseView.rootPage`),VM 若挂在视图的 `@State` 上,切到别的来源再切回来
/// 就是新对象:会话目录缓存清空、回到片库根、再列一次目录。挂在这里,切回来停在原处,零请求。
@MainActor
@Observable
final class FileSourceViewModelStore {
    private let container: AppContainer
    /// 不参与观察:建出后不替换,`viewModel(for:)` 可在视图求值时按需建
    @ObservationIgnored private var viewModels: [UUID: FileSourceViewModel] = [:]

    init(container: AppContainer) {
        self.container = container
    }

    func viewModel(for source: FileSource) -> FileSourceViewModel {
        if let existing = viewModels[source.id] { return existing }
        let created = FileSourceViewModel(container: container, source: source)
        viewModels[source.id] = created
        return created
    }

    /// 删掉的来源不再留着
    func retain(sourceIDs: Set<UUID>) {
        viewModels = viewModels.filter { sourceIDs.contains($0.key) }
    }
}
