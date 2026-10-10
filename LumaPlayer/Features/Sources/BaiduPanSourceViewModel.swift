import Foundation
import Observation

/// 百度网盘源那一页的状态(ViewModel)。
///
/// 它是**独立的一页**,不属于 `BrowseView` 的导航栈:百度源与「当前 Emby 服务器」
/// 没有任何关系,把它塞进 Emby 的栈里会让「切服务器 → 清空导航栈」这条规则
/// 变得说不通(文档 §6:新增一个**平行的**源,不改造 Emby 那条路)。
@MainActor
@Observable
final class BaiduPanSourceViewModel {

    // MARK: - 授权

    /// 现在该显示哪一屏。nil = 还在判定
    private(set) var authorization: BaiduPanAuthorization?
    private(set) var loadFailure: LoadFailure?
    private(set) var isLoading = false

    /// 正在等扫码(device code 已拿到)
    private(set) var deviceCode: BaiduPanDeviceCode?
    private(set) var isWaitingForAuthorization = false
    /// 二维码渲染失败、片库根存不进去之类的本地提示(不打断当前流程)
    private(set) var notice: String?

    // MARK: - 目录

    /// 应用目录名(展示用:空状态里要告诉用户把片子放进哪个目录)
    private(set) var folderName: String?
    /// 应用根目录 `/apps/{应用目录名}`。第三方应用能访问的**全部范围**(§2.1)
    private(set) var rootDirectory: String?
    /// 片库根:用户在应用目录**内部**选定的起点。nil = 就用应用目录
    private(set) var libraryRoot: String?
    /// 当前目录
    private(set) var currentDirectory: String?
    private(set) var files: [BaiduPanFile] = []
    private(set) var isLoadingFiles = false
    private(set) var directoryFailure: BaiduPanDirectoryFailure?

    /// 用户主动要改配置时(多半是应用目录名填错了)预填给表单的现值。
    private(set) var configurationDraft: BaiduPanConfigurationDraft?

    /// 本地续播进度(fs_id → 已看秒数),用于列表上画一行「已看到 12:34」
    private(set) var resumePositions: [String: Double] = [:]

    private let container: AppContainer
    private var authorizationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    private var connection: BaiduPanConnection { container.baiduConnection() }

    // MARK: - 动作:进入

    func reload() async {
        loadTask?.cancel()
        // `_ =` 是必要的:`self?.performReload()` 的结果是 `Void?`,
        // 直接当闭包返回值会让 Task 变成 `Task<()?, Never>`。
        let task = Task { [weak self] in _ = await self?.performReload() }
        loadTask = task
        await task.value
    }

    private func performReload() async {
        isLoading = true
        loadFailure = nil
        defer { isLoading = false }
        do {
            authorization = try await connection.authorization()
            // 目录名只用于展示。⛔ 这里的 `try?` 不是吞错:凭据文件读不出来时
            // 上面的 `authorization()` 已经抛了同样的错误并进了 `loadFailure`。
            folderName = try? await connection.appConfiguration().folderName
            switch authorization {
            case .authorized:
                // ⚠️ 进这一屏一律**从片库根重新开始**:`reload()` 只在结构性变化后
                // 被调用(首次进入 / 授权完成 / 保存配置 / 解除授权),那些情况下
                // 停在上次浏览的子目录没有意义。路径栏那个刷新按钮走的是
                // `loadFiles()`,它**不会**重置当前目录 —— 那里不该把人弹回去。
                currentDirectory = nil
                await loadFiles()
            case .needsAuthorization:
                break
            case .unconfigured, nil:
                break
            }
        } catch let error as BaiduPanError {
            // ⚠️「还没配置」不是失败,是这一页的第一屏 —— 走配置表单,不报错
            if error == .appCredentialsMissing {
                authorization = .unconfigured
            } else {
                authorization = nil
                loadFailure = LoadFailure(message: error.userMessage)
            }
        } catch {
            authorization = nil
            loadFailure = LoadFailure(message: "读取百度网盘授权状态失败:\(error)")
        }
    }

    // MARK: - 动作:配置

    func saveConfiguration(appKey: String, secretKey: String, folderName: String) async {
        do {
            try await connection.saveConfiguration(
                appKey: appKey, secretKey: secretKey, folderName: folderName)
            await reload()
        } catch let error as BaiduPanError {
            loadFailure = LoadFailure(message: error.userMessage)
        } catch {
            loadFailure = LoadFailure(message: "保存配置失败:\(error)")
        }
    }

    // MARK: - 动作:授权

    func startAuthorization() async {
        guard !isWaitingForAuthorization else { return }
        isWaitingForAuthorization = true
        loadFailure = nil
        notice = nil
        do {
            deviceCode = try await connection.startDeviceAuthorization()
        } catch let error as BaiduPanError {
            loadFailure = LoadFailure(message: error.userMessage)
            isWaitingForAuthorization = false
            return
        } catch {
            loadFailure = LoadFailure(message: "获取授权二维码失败:\(error)")
            isWaitingForAuthorization = false
            return
        }
        guard let deviceCode else { return }
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in await self?.poll(deviceCode) }
    }

    private func poll(_ code: BaiduPanDeviceCode) async {
        do {
            _ = try await connection.awaitAuthorization(code)
            isWaitingForAuthorization = false
            deviceCode = nil
            await reload()
        } catch is CancellationError {
            // 用户点了取消:回到「需要授权」那一屏,不报错
            isWaitingForAuthorization = false
            deviceCode = nil
        } catch let error as BaiduPanError {
            isWaitingForAuthorization = false
            deviceCode = nil
            loadFailure = LoadFailure(message: error.userMessage)
        } catch {
            isWaitingForAuthorization = false
            deviceCode = nil
            loadFailure = LoadFailure(message: "授权失败:\(error)")
        }
    }

    func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
        isWaitingForAuthorization = false
        deviceCode = nil
    }

    func signOut() async {
        do {
            try await connection.signOut()
            files = []
            currentDirectory = nil
            // 片库根**保留**(与 AppKey / SecretKey 同一条理由):
            // 重新扫码不该逼用户再选一次片库在哪。
            await reload()
        } catch {
            loadFailure = LoadFailure(message: "解除授权失败:\(error)")
        }
    }

    /// 用户主动要改配置(典型场景:应用目录名填错,整页空着)。
    ///
    /// ⛔ 只把界面切回表单,**不动 token** —— 改个目录名不该连带重新扫码。
    func beginConfigurationEdit() async {
        // 读不出来就没有现值可预填,给一张空表单(排在这一步的错误已经进过 `loadFailure`)。
        if let configuration = try? await connection.appConfiguration() {
            configurationDraft = BaiduPanConfigurationDraft(
                appKey: configuration.appKey,
                secretKey: configuration.secretKey,
                folderName: configuration.folderName
            )
        } else {
            configurationDraft = nil
        }
        authorization = .unconfigured
    }

    /// 改配置改到一半又不想改了:回到授权后的那一屏。
    func cancelConfigurationEdit() async {
        configurationDraft = nil
        await reload()
    }

    // MARK: - 动作:目录

    func loadFiles() async {
        await loadFiles(allowingLibraryRootFallback: true)
    }

    /// `allowingLibraryRootFallback`:片库根读不出来时,允许清掉它并回落到应用目录。
    ///
    /// ⛔ 只回落**一次**。递归时传 false:再失败就是应用目录本身的问题,
    /// 继续套娃只会把真正的错误(目录名填错)藏在一层层的重试里。
    private func loadFiles(allowingLibraryRootFallback allowFallback: Bool) async {
        isLoadingFiles = true
        directoryFailure = nil
        defer { isLoadingFiles = false }

        var directory = ""
        do {
            let root = try await connection.applicationDirectory()
            rootDirectory = root
            let library = try await connection.libraryRoot()
            libraryRoot = library
            directory = currentDirectory ?? library ?? root
            currentDirectory = directory
            files = try await connection.files(inDirectory: directory)
            await loadResumePositions()
            return
        } catch let error as BaiduPanError {
            // 片库根在网盘里被删了 / 改了名 → 丢掉这个偏好,回落到应用目录。
            // ⛔ 不弹错误:它只是个「记住上次在哪」的便利,不值得为此打断浏览。
            if allowFallback, error.isDirectoryUnavailable,
               let library = libraryRoot, directory == library, directory != rootDirectory {
                try? await connection.setLibraryRoot(nil)
                libraryRoot = nil
                currentDirectory = nil
                await loadFiles(allowingLibraryRootFallback: false)
                return
            }
            directoryFailure = BaiduPanDirectoryFailure(
                message: error.userMessage,
                isApplicationRootUnavailable: error.isDirectoryUnavailable
                    && directory == rootDirectory
            )
        } catch {
            directoryFailure = BaiduPanDirectoryFailure(
                message: "读取目录失败:\(error)", isApplicationRootUnavailable: false)
        }
    }

    func enter(_ file: BaiduPanFile) async {
        guard file.isDirectory else { return }
        currentDirectory = file.path
        await loadFiles()
    }

    func goUp() async {
        guard let current = currentDirectory, let root = rootDirectory,
              current != root else { return }
        let parent = (current as NSString).deletingLastPathComponent
        // ⛔ 不许退到应用目录之外:那以外的地方第三方应用访问不了(§2.1)
        currentDirectory = parent.hasPrefix(root) ? parent : root
        await loadFiles()
    }

    var canGoUp: Bool {
        guard let current = currentDirectory, let root = rootDirectory else { return false }
        return current != root
    }

    // MARK: - 动作:片库根

    /// 片库根是「进来先落在哪」的选择,不是授权范围 —— 授权范围由
    /// `/apps/{应用目录名}` 一个值决定,用户改不了(§2.1),所以百度那边
    /// **没有**「授权时选文件夹」这一步;能选的只有应用目录**里面**的起点。
    var isCurrentDirectoryLibraryRoot: Bool {
        guard let library = libraryRoot, let current = currentDirectory else { return false }
        return current == library
    }

    /// 应用目录本身就是默认起点,把它设成片库根没有意义(等于没设)。
    var canSetLibraryRoot: Bool {
        guard let current = currentDirectory, let root = rootDirectory, current != root else {
            return false
        }
        return !isCurrentDirectoryLibraryRoot
    }

    func setLibraryRootToCurrentDirectory() async {
        guard let current = currentDirectory else { return }
        do {
            try await connection.setLibraryRoot(current)
            libraryRoot = current
        } catch let error as BaiduPanError {
            notice = error.userMessage
        } catch {
            notice = "设置片库根失败:\(error)"
        }
    }

    func clearLibraryRoot() async {
        do {
            try await connection.setLibraryRoot(nil)
            libraryRoot = nil
            currentDirectory = nil
            await loadFiles()
        } catch let error as BaiduPanError {
            notice = error.userMessage
        } catch {
            notice = "清除片库根失败:\(error)"
        }
    }

    /// 当前目录相对应用根目录的显示路径
    var relativePath: String? {
        guard let current = currentDirectory, let root = rootDirectory else { return nil }
        if current == root { return "/" }
        guard current.hasPrefix(root) else { return current }
        let remainder = String(current.dropFirst(root.count))
        return remainder.isEmpty ? "/" : remainder
    }

    func play(_ file: BaiduPanFile) {
        container.play(file)
    }

    func resumeSeconds(for file: BaiduPanFile) -> Double? {
        resumePositions[String(file.fsID)]
    }

    /// 修改配置时预填给表单的现值。
    struct BaiduPanConfigurationDraft: Sendable, Equatable {
        let appKey: String
        let secretKey: String
        let folderName: String
    }

    private func loadResumePositions() async {
        var result: [String: Double] = [:]
        for file in files where file.kind.isPlayable {
            if let seconds = await container.watchProgress.resumeSeconds(forFileID: String(file.fsID)) {
                result[String(file.fsID)] = seconds
            }
        }
        resumePositions = result
    }
}

/// 目录读失败时的用户可见信息。
///
/// ⚠️ 没有复用 `LoadFailure`:那一个是给 Emby 那条的(带 `needsLogin`),
/// 而这里的分支是百度独有的,塞进去会让两个源的状态互相污染。
struct BaiduPanDirectoryFailure: Sendable, Equatable {
    let message: String

    /// 是不是**应用目录本身**读不出来(`/apps/{应用目录名}` 不在 / 没权限)。
    ///
    /// 这一态要给完全不同的处置:重试没用,得让人去核对控制台里的「应用名称」。
    /// ⛔ 它**不是**「大概是权限问题」的猜测 —— 只有 `errno` 是
    /// `-7`(无权访问)/ `-9`(不存在)且失败的请求正是应用目录时才置 true。
    let isApplicationRootUnavailable: Bool
}
