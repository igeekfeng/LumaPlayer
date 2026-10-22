import SwiftUI

/// 删除确认面板:**只在本机隐藏**,还是**连网盘里的文件一起删**。
///
/// 本地文件夹来源只读(`FileSource.supportsDeletingFiles`):没有那个开关,只剩「隐藏」。
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
///
/// ## 两条路都会清掉观看记录
///
/// 用户的要求是「删剧集的时候同步删掉观看记录、继续观看里该剧集的内容」——
/// 所以「隐藏」与「真删」都会把这一条(目录则是里面每一集)的本地进度清掉,
/// 它也就不再出现在「继续观看」里。⚠️ 恢复隐藏**不会**把进度还回来:
/// 进度是真删了,条目本身会回到列表。副标题把这件事写出来,⛔ 不让人以为
/// 恢复能复原一切。
struct FileSourceDeleteItemView: View {
    let item: SourceItem
    let viewModel: FileSourceViewModel
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

            if viewModel.source.supportsDeletingFiles {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
                    Toggle("同时删除网盘里的文件", isOn: $alsoDeleteRemotely)
                        .disabled(isDeleting)
                }
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.top, Metrics.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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

    /// ⚠️ 必须说清「观看记录也一起清」:这是一个**不可撤销**的副作用,
    /// 而「隐藏」这个字面上看着最轻的选项也会触发它。
    private var localSubtitle: String {
        let storage = viewModel.source.storageNoun
        return (item.kind.isContainer
            ? "只会从这里的列表里消失,\(storage)里的文件还在。"
            : "只会从这里的列表里消失,\(storage)里的这个文件还在。")
            + "这一项的本地观看记录会一起清掉,「继续观看」里的卡片也随之消失"
            + "(恢复隐藏不会把进度还回来)。可以在设置 →「已隐藏」里恢复这一项。"
    }

    /// ⚠️ 文件夹要说清「连里面的内容一起」:实测删除是**递归**的
    /// (`docs/BAIDU_PAN_API.md` §2.4),删一个季目录等于删掉整季。
    private var remoteSubtitle: String {
        let files = item.kind.isContainer
            ? "网盘上这个文件夹会连同里面的内容一起删掉,"
            : "网盘上的这个文件也会被删掉,"
        return files + "该操作无法撤销。"
            + (item.kind.isContainer
                ? "里面每一集的本地观看记录也会一起清掉,「继续观看」里不再有这部的内容。"
                : "它的本地观看记录也会一起清掉,「继续观看」里不再有它。")
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
        } catch let error as LocalFolderError {
            dismiss()
            onFailure(error.userMessage)
        } catch {
            dismiss()
            onFailure("删除失败:\(error)")
        }
    }
}
