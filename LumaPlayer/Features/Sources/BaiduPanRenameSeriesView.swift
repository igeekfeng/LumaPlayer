import SwiftUI

/// 把**整个剧集目录**改成标准 TMDB 命名的面板:列目录 → 认剧(要你确认) → 预览 → 执行。
///
/// ⛔ 认剧不自动挑一个 —— 挑错就是整目录按错的剧改名;预览要把改名 / 跳过清单与配额都摆出来。
/// 执行后网盘里的名字就变了(百度没有 undo),所以底部给「撤销这次改名」,
/// 它只能撤销**已确认成功**的部分。
struct BaiduPanRenameSeriesView: View {
    @Bindable var viewModel: BaiduPanRenameSeriesViewModel
    let directory: BaiduPanFile
    /// 关掉面板后让浏览页刷新一次 —— 名字全变了,缓存里的旧目录已经不对了。
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int?
    @State private var didStart = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "arrow.triangle.2.circlepath",
                title: "重命名「\(directory.name)」",
                subtitle: subtitle)
            Divider()
            content
            Divider()
            actionBar
        }
        .frame(minWidth: 660, minHeight: 500)
        // ⚠️ `.task` 会随 stage 变化重复触发,用 `didStart` 兜住,⛔ 否则每进一个阶段白烧一次列目录。
        .task {
            guard !didStart else { return }
            didStart = true
            await viewModel.start(directory: directory)
        }
        .interactiveDismissDisabled(viewModel.stage == .executing)
        .alert("无法继续", isPresented: Binding(
            get: { viewModel.failure != nil },
            set: { if !$0 { viewModel.dismissFailure() } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.failure ?? "")
        }
    }

    private var subtitle: String {
        switch viewModel.stage {
        case .idle, .preparing:
            return "把剧集目录、季目录与集文件一起改成 Plex / Emby 认得出的标准命名。"
        case .choosingSeries:
            return "先确认这是哪一部剧 —— 选错会按错的剧改名。"
        case .preview:
            return "下面就是要改成的名字,确认后再提交。"
        case .executing:
            return "正在提交,别关掉这个面板。"
        case .finished:
            return "改名结束。"
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch viewModel.stage {
        case .idle:
            placeholder(systemImage: "arrow.triangle.2.circlepath", text: "准备中…")
        case .preparing(let text):
            waiting(text)
        case .choosingSeries:
            candidatesPane
        case .preview:
            previewPane
        case .executing:
            waiting("正在提交改名…")
        case .finished:
            finishedPane
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: Metrics.spacingM) {
            ProgressView()
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: Metrics.spacingS) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 认剧

    private var candidatesPane: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Text("TMDB 上找到 \(viewModel.candidates.count) 个可能,选一个再继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(viewModel.candidates, id: \.tmdbID, selection: $selection) { match in
                HStack(alignment: .top, spacing: Metrics.spacingM) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.title ?? "(TMDB 没给标题)")
                        Text(candidateDetail(match))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let overview = match.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: 340, alignment: .trailing)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .padding(Metrics.spacingL)
    }

    private func candidateDetail(_ match: TMDBMatch) -> String {
        let year = match.year.map { "首播 \($0)" } ?? "首播年未知"
        return "tmdbid-\(match.tmdbID) · \(year)"
    }

    // MARK: - 预览

    @ViewBuilder
    private var previewPane: some View {
        if let plan = viewModel.plan {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    Text(summary(plan))
                        .font(.callout)
                    if plan.isFlat {
                        Text("剧根下没有季文件夹 —— 这些集按第 1 季(S01)处理,不新建 Season 01 目录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(quotaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !plan.items.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.spacingS) {
                            Text("要改的").font(.headline)
                            ForEach(plan.items, id: \.fsID) { row($0) }
                        }
                    }
                    if !plan.skipped.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.spacingS) {
                            Text("不改的(\(plan.skipped.count))").font(.headline)
                            ForEach(plan.skipped, id: \.fsID) { skipped in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((skipped.path as NSString).lastPathComponent)
                                            .font(.system(.caption, design: .monospaced))
                                        Text(skipped.reason.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Metrics.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ item: BaiduPanRenamePlanner.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
            Image(systemName: item.isUnchanged ? "checkmark.circle" : "arrow.right")
                .foregroundStyle(item.isUnchanged ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.oldName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(item.isUnchanged ? .secondary : .primary)
                if !item.isUnchanged {
                    Text(item.newName)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private func summary(_ plan: BaiduPanRenamePlanner.Plan) -> String {
        let unchanged = plan.items.count - plan.actionableCount
        var text = "共 \(plan.items.count) 项,其中 \(plan.actionableCount) 项要改"
        if unchanged > 0 { text += ",\(unchanged) 项已经符合标准命名" }
        if !plan.skipped.isEmpty { text += ";\(plan.skipped.count) 项跳过" }
        return text
    }

    /// ⚠️ 配额见 `BAIDU_PAN_API.md` §7,这个数字必须让用户看见。
    private var quotaLine: String {
        "已用 \(viewModel.listingRequests) 次百度请求列目录,提交还要 \(viewModel.plannedBatchCount) 次。"
    }

    // MARK: - 结果

    @ViewBuilder
    private var finishedPane: some View {
        if let outcome = viewModel.outcome {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    Text("改好了 \(outcome.succeeded.count) 项"
                         + (outcome.failures.isEmpty ? "" : ",失败 \(outcome.failures.count) 项"))
                        .font(.callout)
                    Text("本次提交 \(outcome.submittedBatches) 次请求。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if outcome.stoppedEarly {
                        Text("中途停下:后面的批次没有再提交,已经改好的部分可以撤销。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !outcome.failures.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.spacingS) {
                            Text("失败明细").font(.headline)
                            ForEach(outcome.failures, id: \.item.fsID) { failure in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(failure.item.oldName)
                                        .font(.system(.caption, design: .monospaced))
                                    Text(failure.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(Metrics.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 底部按钮

    private var actionBar: some View {
        HStack(spacing: Metrics.spacingM) {
            if viewModel.stage == .finished,
               let outcome = viewModel.outcome, !outcome.succeeded.isEmpty {
                Button("撤销这次改名") { Task { await viewModel.rollback() } }
                    .disabled(viewModel.isBusy)
            }
            Spacer(minLength: 0)
            Button("关闭") {
                dismiss()
                onFinished()
            }
            if viewModel.stage == .choosingSeries {
                Button("用这部") { Task { await confirmSelection() } }
                    .disabled(selection == nil || viewModel.isBusy)
            }
            if viewModel.stage == .preview {
                Button("执行改名") { Task { await viewModel.execute() } }
                    .disabled(viewModel.isBusy || (viewModel.plan?.actionableCount ?? 0) == 0)
            }
        }
        .padding(Metrics.spacingL)
    }

    private func confirmSelection() async {
        guard let match = viewModel.candidates.first(where: { $0.tmdbID == selection }) else {
            return
        }
        await viewModel.choose(match)
    }
}
