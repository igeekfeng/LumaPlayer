import SwiftUI

/// 115 网盘来源的设置(设置 →「来源」→ 选中 115 网盘 → 编辑…)。
///
/// 与 `BaiduPanSourceSettingsView` 同形(sheet + header + `Form` + action bar),改**显示名**与
/// **片库根**。差别:
/// - 片库根可以是整个网盘根 `"/"`(115 没有应用目录限制)。
/// - ⚠️ 登录凭据(Cookie)**不在这里改**:它所有 115 来源共用,改它的路是扫码,
///   在浏览页的扫码屏(`Pan115AuthorizationView`)。
struct Pan115SourceSettingsView: View {
    let container: AppContainer
    let source: Pan115Source

    /// 编辑中的显示名
    @State private var displayName: String
    /// 编辑中的片库根(**保存时才写库**,与显示名同一批提交)。nil = 没设。
    @State private var root: Pan115LibraryRoot?
    /// 磁盘上的现值(判断有没有改,没改就不发写请求)
    @State private var savedDisplayName = ""
    @State private var savedRoot: Pan115LibraryRoot?

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showsDirectoryPicker = false
    @State private var showsSignOutConfirmation = false
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(container: AppContainer, source: Pan115Source) {
        self.container = container
        self.source = source
        _displayName = State(initialValue: source.displayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "externaldrive.connected.to.line.below",
                title: "115 网盘",
                subtitle: "片库根决定进来时先落在哪个目录。一个来源一个 ——"
                    + "想再要一个起点,就在来源列表里再加一个 115 来源(共用同一份登录)。"
            )

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }

            OnboardingActionBar(
                primaryTitle: "保存",
                busyTitle: "正在保存…",
                isBusy: isSaving,
                canSubmit: !isSaving && !isLoading,
                onCancel: { dismiss() },
                onSubmit: submit
            )
        }
        .frame(width: Metrics.onboardingFormWidth, height: Self.windowHeight)
        .task { await load() }
        .sheet(isPresented: $showsDirectoryPicker) {
            Pan115DirectoryPickerView(container: container) { path in
                root = Pan115LibraryRoot(path: path, name: (path as NSString).lastPathComponent)
            }
        }
        .confirmationDialog(
            "退出登录",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) { Task { await signOut() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除本机保存的 115 登录 Cookie,回到扫码那一屏。"
                + "片库根都保留 —— 重新扫码即可继续用。")
        }
    }

    /// 与 `ServerSettingsView` 同一口径的固定高度。
    private static let windowHeight: CGFloat = 440

    // MARK: - 表单

    private var form: some View {
        Form {
            if let errorMessage {
                Section { OnboardingNotice(text: errorMessage, style: .error) }
            }
            nameSection
            libraryRootSection
            authorizationSection
        }
        .formStyle(.grouped)
        .disabled(isSaving)
    }

    private var nameSection: some View {
        Section {
            TextField("名称", text: $displayName, prompt: Text("115 网盘"))
                .autocorrectionDisabled()
        } header: {
            Text("名称")
        } footer: {
            Text("显示在来源列表与工具栏的来源菜单里。有多个 115 来源时,"
                + "起个能区分的名字(例如「115 网盘 · 电影」)。")
        }
    }

    private var libraryRootSection: some View {
        Section {
            if let root {
                HStack(spacing: Metrics.spacingM) {
                    VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                        Text(root.displayName)
                            .lineLimit(1)
                        Text(root.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: Metrics.spacingM)
                    Button("更改…") { showsDirectoryPicker = true }
                        .buttonStyle(.borderless)
                    Button("移除", role: .destructive) { self.root = nil }
                        .buttonStyle(.borderless)
                        .help("不再固定起点,进来时落在网盘根")
                }
            } else {
                Text("还没有片库根,进来时会落在网盘根。")
                    .foregroundStyle(.secondary)
                Button {
                    showsDirectoryPicker = true
                } label: {
                    Label("从网盘选择…", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("片库根")
        } footer: {
            Text("片库根是网盘里的一个起点目录(例如 /电影)。它只是「从哪开始」的书签,"
                + "不影响能访问什么 —— 浏览页也不会退到它之上,它就是那一页的最外层。")
        }
    }

    private var authorizationSection: some View {
        Section {
            Button("退出登录", role: .destructive) {
                showsSignOutConfirmation = true
            }
        } header: {
            Text("登录")
        } footer: {
            Text("登录是**所有 115 来源共用**的:退出之后,每个 115 来源都会回到扫码那一屏。")
        }
    }

    // MARK: - 动作

    private func load() async {
        do {
            root = try await container.pan115LibraryRoot(for: source)
            savedRoot = root
            errorMessage = nil
        } catch {
            errorMessage = "读取片库根失败:\(error)"
        }
        savedDisplayName = source.displayName
        displayName = source.displayName
        isLoading = false
    }

    private func submit() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                if root != savedRoot {
                    try await container.setPan115LibraryRoot(root, for: source)
                }
                let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != savedDisplayName {
                    try await container.renamePan115Source(source, displayName: trimmed)
                }
                dismiss()
            } catch let error as Pan115Error {
                errorMessage = error.userMessage
            } catch {
                errorMessage = "保存失败:\(error)"
            }
            isSaving = false
        }
    }

    private func signOut() async {
        do {
            try await container.signOutPan115()
            dismiss()
        } catch {
            errorMessage = "退出登录失败:\(error)"
        }
    }
}
