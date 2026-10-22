import Foundation

/// 把改名计划提交到网盘:按层分批(层内多条一起送,层间必须串行,`docs/BAIDU_PAN_API.md` §2.6),
/// 经注入的 `submit` 发请求(本层不发请求),按 `info[].errno` 折逐条结果。⛔ 不决定名字。
///
/// 任何一批失败就停,后续批次不再提交:中间层没改成时,下面已改文件的新路径推不出来,撤销清单就算不清。
enum BaiduPanRenameExecutor {

    struct Failure: Sendable, Equatable {
        let item: BaiduPanRenamePlanner.Item
        /// `0` = 整批请求没拿到结果,而不是逐条失败。
        let errno: Int
        let message: String
    }

    struct Outcome: Sendable, Equatable {
        /// 已确认成功的条目(按提交顺序),撤销清单由它生成。
        let succeeded: [BaiduPanRenamePlanner.Item]
        let failures: [Failure]
        let stoppedEarly: Bool
        /// 实际请求次数,UI 必须显示给用户(配额见 §7)。
        let submittedBatches: Int

        var isFullySucceeded: Bool { failures.isEmpty }

        static var empty: Outcome {
            Outcome(succeeded: [], failures: [], stoppedEarly: false, submittedBatches: 0)
        }
    }

    // MARK: - 入口

    /// - Parameters:
    ///   - plan: 条目已按执行顺序排好。
    ///   - submit: 提交一批,返回逐条结果(顺序与入参一致)。
    static func run(
        plan: BaiduPanRenamePlanner.Plan,
        batchLimit: Int = Self.defaultBatchLimit,
        submit: @Sendable ([BaiduPanRenameOperation])
            async throws -> [BaiduPanFileManagerResponse.Info]
    ) async -> Outcome {
        let pending = plan.items.filter { !$0.isUnchanged }
        guard !pending.isEmpty else { return .empty }

        var succeeded: [BaiduPanRenamePlanner.Item] = []
        var failures: [Failure] = []
        var submitted = 0

        for batch in batches(of: pending, batchLimit: batchLimit) {
            let operations = batch.map {
                BaiduPanRenameOperation(path: $0.oldPath, newName: $0.newName)
            }
            submitted += 1

            do {
                let info = try await submit(operations)
                // ⚠️ 按位置对应(§2.7 第 3 条未实测;条数校验在 client 层)
                for (index, entry) in info.enumerated() {
                    guard index < batch.count else { break }
                    let item = batch[index]
                    if entry.errno == 0 {
                        succeeded.append(item)
                    } else {
                        failures.append(Failure(
                            item: item,
                            errno: entry.errno,
                            message: Self.describe(errno: entry.errno)))
                    }
                }
            } catch {
                // 整批没拿到结果。⛔ 不假设一条都没生效:服务端可能已处理一部分
                for item in batch {
                    failures.append(Failure(
                        item: item, errno: 0,
                        message: "这一批没有拿到逐条结果:\(Self.describe(error))"
                            + "(可能已部分生效,请先刷新确认)"))
                }
            }

            if !failures.isEmpty {
                return Outcome(
                    succeeded: succeeded, failures: failures,
                    stoppedEarly: true, submittedBatches: submitted)
            }
        }

        return Outcome(
            succeeded: succeeded, failures: failures,
            stoppedEarly: false, submittedBatches: submitted)
    }

    /// 未实测的保守值(§2.7 第 1 条)。
    static let defaultBatchLimit = 50

    // MARK: - 分批

    /// 按层(`target.order`)切开,层内再按 `batchLimit` 分片。
    /// 计划已排好序、同层连续,⛔ 不按层号重新排序分组(会打乱层内的确定性顺序)。
    static func batches(of items: [BaiduPanRenamePlanner.Item], batchLimit: Int) -> [[BaiduPanRenamePlanner.Item]] {
        guard !items.isEmpty else { return [] }

        var layers: [[BaiduPanRenamePlanner.Item]] = []
        var current: [BaiduPanRenamePlanner.Item] = []
        for item in items {
            if let last = current.last, last.target.order != item.target.order {
                layers.append(current)
                current = []
            }
            current.append(item)
        }
        if !current.isEmpty { layers.append(current) }

        guard batchLimit > 0 else { return layers }
        return layers.flatMap { layer -> [[BaiduPanRenamePlanner.Item]] in
            stride(from: 0, to: layer.count, by: batchLimit).map { start in
                Array(layer[start..<Swift.min(start + batchLimit, layer.count)])
            }
        }
    }

    // MARK: - 撤销

    /// 把已确认成功的条目改回原名。顺序反向(自顶向下):先还原剧根,下面的路径才定位得到。
    static func rollbackOperations(for outcome: Outcome) -> [BaiduPanRenameOperation] {
        outcome.succeeded.reversed().map { item in
            BaiduPanRenameOperation(path: item.renamedPath, newName: item.oldName)
        }
    }

    // MARK: - 文案

    /// 复用 `BaiduPanError` 的映射,⛔ 不另写一份。
    private static func describe(errno: Int) -> String {
        BaiduPanError.server(errno: errno, message: nil).userMessage
    }

    private static func describe(_ error: any Error) -> String {
        (error as? BaiduPanError)?.userMessage ?? "\(error)"
    }
}

extension BaiduPanRenamePlanner.Item {
    /// 推算出的新路径,用于本地缓存与撤销清单。⛔ 不当请求参数(提交永远用当前的 `oldPath`)。
    var renamedPath: String {
        (oldPath as NSString).deletingLastPathComponent + "/" + newName
    }
}
