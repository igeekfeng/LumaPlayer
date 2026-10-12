import SwiftUI

/// 删除确认面板:**只在本机隐藏**,还是**连网盘里的文件一起删**。
///
/// ## 为什么是自定义 sheet
///
/// SwiftUI 的 `.alert` / `.confirmationDialog` 装不下 `Toggle` —— 而「要不要真删
/// 网盘文件」必须是**默认不勾**的显式选择。塞进按钮文案里(「删除」/「删除并删除
/// 网盘文件」两条按钮)会让人在没看清楚时选错,而这一条**不可撤销**。
///
/// ## 默认为什么是「只隐藏」
///
/// 隐藏可恢复(设置 →「已隐藏」),真删不可恢复。代价是文件还占着网盘空间,
/// 但比起误删一整季,这个代价小得多 —— 所以默认落在安全的那一侧。
struct BaiduPanDeleteItemView: View {
    let item: SourceItem
    let viewModel: BaiduPanSourceViewModel
    /// 失败文案交给浏览页弹 alert(与 `ServerListView` 的破坏性操作同一范式)
    let onFailure: (String) -> Void

    /// ⚠️ 默认 **false**:不勾 = 只隐藏,勾了才是真删网盘文件。
    @State private var alsoDeleteRemotely = false
    @State private var isDeleting = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "trash",
                title: "删除「\(displayTitle)」",
                subtitle: alsoDeleteRemotely ? remoteSubtitle : localSubtitle
            )

            VStack(alignment: .leading, spacing: Metrics.spacingM) {
                Toggle("同时删除网盘里的文件", isOn: $alsoDeleteRemotely)
                    .disabled(isDeleting)
            }
            .padding(.horizontal, Metrics.spacingXL)
            .padding(.top, Metrics.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: Metrics.spacingM)

            OnboardingActionBar(
                primaryTitle: alsoDeleteRemotely ? "删除文件" : "隐藏",
                busyTitle: "正在处理…",
                isBusy: isDeleting,
                canSubmit: true,
                onCancel: { dismiss() },
                onSubmit: { Task { await confirm() } }
            )
        }
        .frame(width: Metrics.onboardingFormWidth)
        // 删除进行中不允许点外面关掉:那一半已经发出去的请求收不回来
        .interactiveDismissDisabled(isDeleting)
    }

    private var displayTitle: String {
        item.episodeTitle ?? item.title
    }

    private var localSubtitle: String {
        "只会从这里的列表里消失,网盘上的文件还在。之后可以在设置 →「已隐藏」里恢复。"
    }

    /// ⚠️ 文件夹要说清「连里面的内容一起」:实测删除是**递归**的
    /// (`docs/BAIDU_PAN_API.md` §2.4),删一个季目录等于删掉整季。
    private var remoteSubtitle: String {
        item.kind.isContainer
            ? "网盘上这个文件夹会连同里面的内容一起删掉,该操作无法撤销。"
            : "网盘上的这个文件也会被删掉,该操作无法撤销。"
    }

    private func confirm() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await viewModel.delete(item, alsoDeleteRemotely: alsoDeleteRemotely)
            dismiss()
        } catch let error as BaiduPanError {
            dismiss()
            onFailure(error.userMessage)
        } catch {
            dismiss()
            onFailure("删除失败:\(error)")
        }
    }
}
