import SwiftUI

/// 添加本地文件夹来源:选文件夹 →(可选)起个名字 → 落库并切过去。
/// 访问权在这一刻拿到:本次运行直接可读,`AppContainer.addLocalFolderSource` 当场做成安全作用域书签供后续启动。
struct LocalFolderAddView: View {
    let container: AppContainer
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var folder: URL?
    @State private var displayName = ""
    @State private var showsFolderPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            backBar
            Divider()
            OnboardingFormHeader(
                systemImage: "folder.fill",
                title: "添加本地文件夹",
                subtitle: "选择放视频的文件夹(本机、外接盘或已挂载的网络卷都可以)。"
                    + "LumaPlayer 只读取,不会删除或改动里面的文件。"
            )

            Form {
                if let errorMessage {
                    Section { OnboardingNotice(text: errorMessage, style: .error) }
                }
                Section {
                    HStack(spacing: Metrics.spacingM) {
                        if let folder {
                            Text(folder.path)
                                .font(.callout)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        } else {
                            Text("还没有选择文件夹")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Metrics.spacingM)
                        Button(folder == nil ? "选择文件夹…" : "更换…") { showsFolderPicker = true }
                    }
                } header: {
                    Text("文件夹")
                }
                Section {
                    TextField(
                        "名称", text: $displayName,
                        prompt: Text(folder.map(LocalFolderSource.rootName(forFolderAt:)) ?? "本地文件夹"))
                        .autocorrectionDisabled()
                } header: {
                    Text("名称")
                } footer: {
                    Text("显示在来源列表与工具栏的来源菜单里。留空则用文件夹名。")
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            OnboardingActionBar(
                primaryTitle: "添加",
                busyTitle: "正在添加…",
                isBusy: isSaving,
                canSubmit: folder != nil && !isSaving,
                onCancel: nil,
                onSubmit: submit
            )
        }
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                folder = url
                errorMessage = nil
            case .failure(let error):
                errorMessage = "选择文件夹失败:\(error.localizedDescription)"
            }
        }
    }

    private var backBar: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Label("选择其它来源", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            Spacer()
        }
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingS)
    }

    private func submit() {
        guard let folder, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await container.addLocalFolderSource(folderURL: folder, displayName: displayName)
                onDone()
            } catch let error as LocalFolderError {
                errorMessage = error.userMessage
                isSaving = false
            } catch {
                errorMessage = "添加来源失败:\(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}
