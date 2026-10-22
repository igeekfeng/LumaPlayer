import SwiftUI

/// 本地文件夹来源的设置(设置 →「来源」→ 选中本地文件夹 → 编辑…)。能改的只有
/// **显示名**与**指向哪个文件夹**,都是保存时才提交。换文件夹后同名同路径的文件仍记得
/// 看到哪儿、看没看过(条目路径挂在 `LocalFolderSource.rootName` 下)。
struct LocalFolderSourceSettingsView: View {
    let container: AppContainer
    let source: LocalFolderSource

    @State private var displayName: String
    /// 新选的文件夹(nil = 没换)
    @State private var pendingFolder: URL?
    @State private var showsFolderPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(container: AppContainer, source: LocalFolderSource) {
        self.container = container
        self.source = source
        _displayName = State(initialValue: source.displayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "folder.fill",
                title: "本地文件夹",
                subtitle: "只读取这个文件夹里的视频,不会删除或改动你的文件。"
            )

            Form {
                if let errorMessage {
                    Section { OnboardingNotice(text: errorMessage, style: .error) }
                }
                nameSection
                folderSection
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            OnboardingActionBar(
                primaryTitle: "保存",
                busyTitle: "正在保存…",
                isBusy: isSaving,
                canSubmit: !isSaving,
                onCancel: { dismiss() },
                onSubmit: submit
            )
        }
        .frame(width: Metrics.onboardingFormWidth, height: Self.windowHeight)
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): pendingFolder = url
            case .failure(let error): errorMessage = "选择文件夹失败:\(error.localizedDescription)"
            }
        }
    }

    /// 与 `BaiduPanSourceSettingsView` 同一口径
    private static let windowHeight: CGFloat = 420

    private var nameSection: some View {
        Section {
            TextField("名称", text: $displayName, prompt: Text(source.rootName))
                .autocorrectionDisabled()
        } header: {
            Text("名称")
        } footer: {
            Text("显示在来源列表、工具栏的来源菜单与浏览页最外层。留空则用文件夹名。")
        }
    }

    private var folderSection: some View {
        Section {
            HStack(spacing: Metrics.spacingM) {
                Text(pendingFolder?.path ?? source.lastKnownPath)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: Metrics.spacingM)
                Button("更换…") { showsFolderPicker = true }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text("文件夹")
        } footer: {
            Text("文件夹被移动、外接盘换了,或提示没有访问权限时,在这里重新选一次。"
                + "换过去之后,路径相同的文件仍记得看到哪儿、看没看过。")
        }
    }

    private func submit() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                var current = source
                if let pendingFolder {
                    current = try await container.relinkLocalFolder(source, to: pendingFolder)
                }
                let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != source.displayName {
                    try await container.renameLocalFolderSource(current, displayName: trimmed)
                }
                dismiss()
            } catch let error as LocalFolderError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = "保存失败:\(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
