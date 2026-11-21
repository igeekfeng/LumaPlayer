import Foundation

/// 转存请求:把一条搜索结果里的某个链接收进网盘。
struct PanTransferRequest: Sendable, Equatable {
    /// 要转存的分享(已解析)
    let share: PanShareLink
    /// 目标来源 id(用户在「存到哪个网盘」里选的那个已登录来源)
    let targetSourceID: UUID
    /// 目标目录路径(该来源内的绝对路径)。`nil` = 用该来源的片库根
    let targetPath: String?
    /// 资源标题,只用于回执展示
    let resourceTitle: String
}

/// 转存结果。
struct PanTransferOutcome: Sendable, Equatable {
    /// 实际写入的位置(展示给用户「已存到 …」)
    let destination: String
    /// 写进网盘的东西(115 回的就是它收到的 file_id;百度没有这个能力)
    let storedCount: Int?
}

/// 转存的失败。与 `Pan115Error` / `BaiduPanError` 分开:这里是**跨来源**的语义,
/// 上层只关心「这次转存为什么没成」,不该被各家的错误码细节绑住。
enum PanTransferError: Error, Equatable {
    /// 这条链接对应的网盘本版本转存不了(夸克 / UC / 其它)
    case unsupportedShare(String)
    /// 本机没有登录那个网盘的来源
    case noMatchingSource(PanCloudType)
    /// 用户还没选目标
    case noTargetSelected
    /// 目标目录在网盘里不存在(115 不自动建目录)
    case destinationMissing(String)
    /// 底层网盘返回的错误(已脱敏)
    case sourceFailed(String)
    /// 115 的频控冷却中
    case rateLimited(retryAfter: TimeInterval)

    var userMessage: String {
        switch self {
        case .unsupportedShare(let reason): return reason
        case .noMatchingSource(let type):
            return "还没有添加「\(type.displayName)」来源。先在设置里加一个,再回来转存。"
        case .noTargetSelected:
            return "还没有选择存到哪个网盘。"
        case .destinationMissing(let path):
            return "目标目录「\(path)」在网盘里不存在。换一个目录,或先在网盘里建好。"
        case .sourceFailed(let message): return message
        case .rateLimited(let retryAfter):
            let minutes = max(1, Int(retryAfter / 60))
            return "115 正在频控冷却中(还剩约 \(minutes) 分钟),这段时间内不能转存。"
        }
    }
}

/// 转存的编排:按分享的网盘类型,挑一个**已登录的**来源去接。
///
/// 分工:
/// - 它不解析分享(那是 `PanShareLink` 的事);
/// - 它不建目录(写操作,要用户明确同意,见 `PanTransferSheet`);
/// - 它只做「选来源 → 调那家的转存 → 折成统一结果」。
@MainActor
final class PanResourceTransferService {
    /// 注入点:调用方(AppContainer)提供「有哪些已登录来源」与「怎么调那家」。
    ///
    /// 为什么用闭包而不是直接依赖 `AppContainer`:转存只用到「列来源 + 两家连接」,
    /// 直接依赖整个组合根会让这个类型在测试里没法单独构造。
    struct Dependencies {
        /// 当前所有来源(用于按网盘类型挑目标)
        let availableSources: @MainActor () async -> [SourceProfile]
        /// 115 连接(全 App 一份)
        let pan115: @MainActor () -> Pan115Connection
        /// 115 来源的片库根(默认目标目录)
        let pan115LibraryRoot: @MainActor (UUID) async throws -> Pan115LibraryRoot?
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// 能接这条分享的来源(按网盘类型过滤)。空 = 本机没有可用的来源。
    func candidateSources(for share: PanShareLink) async -> [SourceProfile] {
        let all = await dependencies.availableSources()
        switch share {
        case .pan115:
            return all.filter { $0.pan115Source != nil }
        case .baidu:
            return all.filter { $0.baiduPanSource != nil }
        case .quark, .uc, .other:
            // 夸克只有只读 TV 接口,UC / 其它没接 —— 没有可接的来源
            return []
        }
    }

    /// 执行转存。
    ///
    /// - Parameter targetPath: 目标目录。`nil` 时用该来源的片库根;片库根也没设就抛错
    ///   (⛔ 不猜一个目录出来)。
    func transfer(_ request: PanTransferRequest, targetPath: String?) async throws -> PanTransferOutcome {
        guard request.share.isTransferable else {
            throw PanTransferError.unsupportedShare(
                request.share.unsupportedReason ?? "这个链接本版本不能转存。")
        }
        switch request.share {
        case .pan115(let shareCode, let receiveCode):
            return try await transfer115(
                shareCode: shareCode, receiveCode: receiveCode,
                sourceID: request.targetSourceID, targetPath: targetPath)
        case .baidu:
            throw PanTransferError.unsupportedShare(Self.baiduTransferUnsupportedReason)
        case .quark, .uc, .other:
            throw PanTransferError.unsupportedShare(
                request.share.unsupportedReason ?? "这个链接本版本不能转存。")
        }
    }

    /// 百度转存能力的**事实说明**。
    ///
    /// 百度网盘的「分享文件转存」(`POST /apaas/1.0/share/transfer`)属于**付费的企业开发者能力**:
    /// 要买「文件分享服务」并开通分享权限才能用(`pan.baidu.com/union/doc` 的接入指南)。
    /// 本项目走的是**个人开发者**的 OAuth 应用,`scope=basic,netdisk`,拿不到这个接口的权限。
    /// ⇒ 不是「还没做」,是「用现在这套凭据做不到」,所以如实告知而不是留一个会失败的重试。
    static let baiduTransferUnsupportedReason = """
    百度网盘的「分享转存」是付费的企业开发者接口(要单独购买「文件分享服务」),\
    本应用用的是个人开发者授权,没有这个权限。请在百度网盘网页 / App 里手动转存,存好后再回到这里刷新目录。
    """

    // MARK: - 115

    private func transfer115(
        shareCode: String,
        receiveCode: String,
        sourceID: UUID,
        targetPath: String?
    ) async throws -> PanTransferOutcome {
        let connection = dependencies.pan115()
        // 目标目录:显式给的优先;否则用该来源的片库根
        let path: String
        if let targetPath, !targetPath.isEmpty {
            path = targetPath
        } else if let root = try await dependencies.pan115LibraryRoot(sourceID) {
            path = root.path
        } else {
            throw PanTransferError.noTargetSelected
        }

        do {
            // 先列分享根,拿 file_id —— `/share/receive` 只认 id,不认路径
            let snapshot = try await connection.shareSnapshot(
                shareCode: shareCode, receiveCode: receiveCode)
            guard snapshot.isAvailable else {
                throw PanTransferError.sourceFailed("这个 115 分享当前不可用(可能已取消或被限制)。")
            }
            guard !snapshot.entries.isEmpty else {
                throw PanTransferError.sourceFailed("这个 115 分享里没有可转存的条目。")
            }
            // 115 的转存是**整层收下**:分享根下有几个条目就传几个 file_id
            // (单条选择在 115 网页端也是这么做的:选中目录即递归收下)
            let fileIDs = snapshot.entries.map(\.fileID)
            try await connection.transfer(
                shareCode: shareCode, receiveCode: receiveCode,
                fileIDs: fileIDs, toPath: path)
            return PanTransferOutcome(destination: path, storedCount: fileIDs.count)
        } catch let error as Pan115Error {
            throw Self.fold(error)
        }
    }

    /// 115 的错误折成跨来源的语义。
    private static func fold(_ error: Pan115Error) -> PanTransferError {
        switch error {
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .notAuthorized, .badCookie, .kickedOut:
            return .sourceFailed("115 的登录已失效,请重新扫码登录。")
        case .invalidRequest(let detail):
            return .sourceFailed(detail)
        default:
            return .sourceFailed(error.userMessage)
        }
    }
}
