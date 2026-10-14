import Foundation

/// 把一份改名计划**提交到网盘**的执行器。
///
/// ## 它只做三件事
///
/// 1. **分层分批**:`BaiduPanRenamePlanner` 已把条目按「集文件 → 季目录 → 剧根」排好,
///    这里按层切开 —— 层内可以多条一起送,层与层之间**必须串行**
///    (`docs/BAIDU_PAN_API.md` §2.6:`path` 定位在父目录改名后立刻失效);
/// 2. **提交**:发请求这件事由调用方注入的 `submit` 做(⛔ 本层不发请求,好测);
/// 3. **折结果**:顶层 `errno=0` 只表示受理,成败在 `info[].errno` 里。
///
/// ⛔ 它**不决定叫什么名字**(那是计划生成器的事),也不判断该不该改。
///
/// ## 失败就停
///
/// 任何一批出现失败,**后续批次不再提交**。
///
/// 理由不是保守,是**回滚能力**:撤销清单要按「改名后」的路径去定位,而一旦
/// 中间某层没改成(比如季目录还是 `S0`),它下面已经改好的那些文件的新路径
/// 就推不出来 —— 继续往下改只会让「哪些改了、在哪」变成一笔算不清的账。
/// 停下来的代价是多按一次「重试」,不停的代价是留下一半改名、还撤不回去。
enum BaiduPanRenameExecutor {

    /// 一条失败的改名。
    struct Failure: Sendable, Equatable {
        let item: BaiduPanRenamePlanner.Item
        /// 百度给的 errno。`0` = 不是逐条失败,而是整批请求就没拿到结果。
        let errno: Int
        let message: String
    }

    /// 一次执行的结果。
    struct Outcome: Sendable, Equatable {
        /// 已确认改成功的条目(按提交顺序)。撤销清单由它生成。
        let succeeded: [BaiduPanRenamePlanner.Item]
        let failures: [Failure]
        /// 是不是中途停下的(有失败 → 后续批次没再提交)。
        let stoppedEarly: Bool
        /// 实际发出去几次请求 —— UI 要显示「本次消耗多少配额」。
        ///
        /// 配额见 `BAIDU_PAN_API.md` §7,这个数字必须让用户看得见。
        let submittedBatches: Int

        var isFullySucceeded: Bool { failures.isEmpty }

        static var empty: Outcome {
            Outcome(succeeded: [], failures: [], stoppedEarly: false, submittedBatches: 0)
        }
    }

    // MARK: - 入口

    /// 按计划提交改名。
    ///
    /// - Parameters:
    ///   - plan: 计划(条目已按执行顺序排好)。
    ///   - batchLimit: 一批最多几条。**未实测**的保守值(§2.7 第 1 条)。
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
                // ⚠️ 按位置对应(§2.7 第 3 条:顺序语义未实测,条数校验已在 client 层做过)
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
                // 整批没拿到结果(传输 / token / 条数对不上)。
                // ⛔ 不假设「一条都没生效」—— 服务端可能已经处理了一部分,
                //   所以这批每一条都记失败,并把话说清楚。
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

    /// 默认批次大小。**未实测**(§2.7 第 1 条),取保守值。
    static let defaultBatchLimit = 50

    // MARK: - 分批

    /// 按层切开,层内再按 `batchLimit` 分片。
    ///
    /// ⚠️ 「层」= `target.order`。计划里的条目已排好序,所以同层是连续的,
    /// 顺序扫一遍就能切出来 —— ⛔ 不按层号排序再分组(那会打乱计划里
    /// 「同层内按路径排」的确定性顺序,让提交顺序变得不可预测)。
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

    /// 撤销清单:把已成功的条目改回原名。
    ///
    /// ⚠️ 顺序是**反向**的:改名自底向上,撤销就得自顶向下 ——
    /// 先还原剧根,否则下面那些已经改好的文件,路径就定位不到了。
    ///
    /// ⛔ 只能撤销**已确认成功**的那部分;失败即停正是为了让这份清单算得出来。
    static func rollbackOperations(for outcome: Outcome) -> [BaiduPanRenameOperation] {
        outcome.succeeded.reversed().map { item in
            BaiduPanRenameOperation(path: item.renamedPath, newName: item.oldName)
        }
    }

    // MARK: - 文案

    /// errno → 能给读者看的话。复用 `BaiduPanError` 现有的映射,⛔ 不另写一份。
    private static func describe(errno: Int) -> String {
        BaiduPanError.server(errno: errno, message: nil).userMessage
    }

    private static func describe(_ error: any Error) -> String {
        (error as? BaiduPanError)?.userMessage ?? "\(error)"
    }
}

extension BaiduPanRenamePlanner.Item {
    /// 改完之后它应该在哪。
    ///
    /// ⚠️ 是**推算**不是服务端回的:用来更新本地缓存与撤销清单,
    /// ⛔ 不拿它当请求参数(提交永远用「当前」的 `oldPath`)。
    var renamedPath: String {
        (oldPath as NSString).deletingLastPathComponent + "/" + newName
    }
}
