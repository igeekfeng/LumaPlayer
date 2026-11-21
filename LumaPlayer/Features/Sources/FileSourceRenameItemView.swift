import SwiftUI

/// 单个文件 / 文件夹的「重命名」面板:只改名字,⛔ 不挪位置、不碰子项、不问 TMDB。
///
/// 与「按 TMDB 重命名…」是两个入口:那个会把整部剧改成标准命名(`BaiduPanRenameSeriesView`),
/// 这个只改最后一段(`docs/BAIDU_PAN_API.md` §2.5)。
///
/// ⚠️ 自定义 sheet 而不是 `.alert` 里塞 `TextField`:输入框要带扩展名提示、要在提交前
/// 就地把「为空 / 带 `/` / 没改」说清楚,`alert` 两样都做不了。
struct FileSourceRenameItemView: View {
    let item: SourceItem
    let viewModel: FileSourceViewModel
    /// 失败文案交给浏览页弹 alert(与删除面板同一范式)
    let onFailure: (String) -> Void

    @State private var name: String
    @State private var isSaving = false
    @State private var failure: String?

    @Environment(\.dismiss) private var dismiss

    init(item: SourceItem, viewModel: FileSourceViewModel, onFailure: @escaping (String) -> Void) {
        self.item = item
        self.viewModel = viewModel
        self.onFailure = onFailure
        // 原名:目录就是目录名,文件是网盘上的完整文件名(⛔ 不用展示标题 —— 那是去掉后缀与发布组之后的)
        _name = State(initialValue: viewModel.renameOriginalName(for: item) ?? item.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "pencil",
                title: "重命名「\(originalName)」",
                subtitle: subtitle)

            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                TextField("新名字", text: $name, prompt: Text(originalName))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(isSaving)
                    .onSubmit { Task { await submit() } }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Metrics.spacingXL)
            .padding(.top, Metrics.spacingL)

            Spacer(minLength: Metrics.spacingM)

            OnboardingActionBar(
                primaryTitle: "重命名",
                busyTitle: "正在改名…",
                isBusy: isSaving,
                canSubmit: BaiduPanSimpleRename.issue(name: name, original: originalName) == nil,
                onCancel: { dismiss() },
                onSubmit: { Task { await submit() } })
        }
        .frame(width: Metrics.onboardingFormWidth)
        // 请求发出去后不允许点外面关掉:网盘那边可能已经改成了
        .interactiveDismissDisabled(isSaving)
    }

    private var originalName: String {
        viewModel.renameOriginalName(for: item) ?? item.title
    }

    private var subtitle: String {
        let kind = item.kind.isContainer ? "文件夹" : "文件"
        return "只改这个名字,\(kind)的位置和里面的内容都不动;"
            + "\(viewModel.source.storageNoun)里的名字会跟着变。"
    }

    /// 提交按钮已经挡住的情况这里不重复说;这里只提醒「改扩展名」这类提交前看不见的后果。
    private var hint: String? {
        if let issue = BaiduPanSimpleRename.issue(name: name, original: originalName) {
            return issue.message
        }
        let original = (originalName as NSString).pathExtension
        let typed = (BaiduPanSimpleRename.cleaned(name) as NSString).pathExtension
        if !original.isEmpty, original.lowercased() != typed.lowercased() {
            return "扩展名从「.\(original)」变成了「\(typed.isEmpty ? "（无）" : "." + typed)」,"
                + "改错的话播放器会认不出这个文件。"
        }
        return nil
    }

    private func submit() async {
        guard !isSaving, BaiduPanSimpleRename.issue(name: name, original: originalName) == nil else {
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await viewModel.rename(item, to: name)
            dismiss()
        } catch let error as BaiduPanError {
            dismiss()
            onFailure(error.userMessage)
        } catch let error as Pan115Error {
            dismiss()
            onFailure(error.userMessage)
        } catch let error as QuarkError {
            dismiss()
            onFailure(error.userMessage)
        } catch let error as LocalFolderError {
            dismiss()
            onFailure(error.userMessage)
        } catch is CancellationError {
            // 面板关掉时在飞的请求被取消:⛔ 不弹「改名失败」
            dismiss()
        } catch {
            dismiss()
            onFailure("重命名失败:\(error)")
        }
    }
}