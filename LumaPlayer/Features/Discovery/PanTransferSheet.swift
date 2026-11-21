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
            // 认得出是分享、但本版本转存不了:⛔ 不提供转存按钮,原因只进悬停提示
            ContentUnavailableView {
                Label("不能转存", systemImage: "nosign")
            } actions: {
                InfoHint(text: share.unsupportedReason ?? "这个链接本版本不能转存。")
            }
        } else if candidates.isEmpty {
            ContentUnavailableView {
                Label("没有能接这个分享的来源", systemImage: "exclamationmark.triangle")
            } actions: {
                SettingsLink {
                    Text("添加来源…")
                }
                .buttonStyle(.borderedProminent)
            }
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
            HStack(spacing: Metrics.spacingS) {
                TextField("目标目录", text: $targetPath, prompt: Text("留空 = 片库根"))
                    .textFieldStyle(.roundedBorder)
                if case .baidu = share {
                    InfoHint(text: PanResourceTransferService.baiduTransferUnsupportedReason)
                }
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
