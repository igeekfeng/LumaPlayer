import SwiftUI

/// 转存确认面板:选「存到哪个已登录网盘」+「存到哪个目录」。
///
/// ⚠️ 这里的取舍都写在界面上,而不是替用户猜:
/// - 只列**真能接这条分享**的来源(夸克只有只读接口 → 不列);
/// - 目标目录必须已存在(115 不自动建目录);
/// - 百度那一档直接说清「个人开发者授权没有转存权限」,⛔ 不给一个必然失败的重试按钮。
struct PanTransferSheet: View {
    let container: AppContainer
    let link: PanResourceLink
    /// 成功后的回执文案
    var onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var share: PanShareLink?
    @State private var candidates: [SourceProfile] = []
    @State private var selectedSourceID: UUID?
    /// 目标目录输入(空 = 用该来源的片库根)
    @State private var targetPath = ""
    @State private var isLoading = true
    @State private var isTransferring = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingL) {
            Text("转存")
                .font(.title2.bold())
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(Metrics.spacingXL)
        .frame(width: Metrics.onboardingFormWidth * 1.4, height: 320)
        .task { await prepare() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let share, !share.isTransferable {
            // 认得出是分享、但本版本转存不了:把原因说清楚,⛔ 不提供转存按钮
            Label {
                Text(share.unsupportedReason ?? "这个链接本版本不能转存。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .foregroundStyle(.secondary)
        } else if candidates.isEmpty {
            Label {
                Text("还没有添加能接这个分享的来源。先在设置里加一个对应的网盘。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.secondary)
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            Picker("存到", selection: $selectedSourceID) {
                ForEach(candidates) { source in
                    Text("\(source.displayName) · \(source.kindDescription)")
                        .tag(Optional(source.id))
                }
            }
            TextField("目标目录(留空 = 该来源的片库根)", text: $targetPath)
                .textFieldStyle(.roundedBorder)
            Text("目录必须已经在网盘里存在 —— 本应用不会替你建目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .baidu = share {
                Text(PanResourceTransferService.baiduTransferUnsupportedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if isTransferring {
                ProgressView().controlSize(.small)
            }
            Button("转存") { Task { await transfer() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canTransfer)
        }
    }

    /// 能点「转存」的条件:认得出的分享 + 有可选来源 + 选了一个来源 + 这个分享本身可转存
    private var canTransfer: Bool {
        guard let share, share.isTransferable else { return false }
        return selectedSourceID != nil && !isTransferring
    }

    private func prepare() async {
        isLoading = true
        defer { isLoading = false }
        guard let parsed = PanShareLink.parse(link.url) else {
            errorMessage = "认不出这个链接是哪家的分享。"
            return
        }
        share = parsed
        candidates = await container.transfer.candidateSources(for: parsed)
        selectedSourceID = candidates.first?.id
    }

    private func transfer() async {
        guard let share, let sourceID = selectedSourceID else { return }
        isTransferring = true
        errorMessage = nil
        defer { isTransferring = false }
        let trimmed = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let outcome = try await container.transfer.transfer(
                PanTransferRequest(
                    share: share,
                    targetSourceID: sourceID,
                    targetPath: trimmed.isEmpty ? nil : trimmed,
                    resourceTitle: ""),
                targetPath: trimmed.isEmpty ? nil : trimmed)
            onDone("已存到 \(outcome.destination)")
            dismiss()
        } catch let error as PanTransferError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "转存失败,请稍后重试。"
        }
    }
}
