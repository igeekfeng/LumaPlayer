import SwiftUI

/// 夸克网盘来源的设置(设置 →「来源」→ 选中夸克网盘 → 编辑…)。
///
/// 与另外两家同形(sheet + header + `Form` + action bar),改**显示名**与**片库根**。差别:
/// - 片库根是整个网盘里的某个目录(TV 端没有应用目录限制)。
/// - 这个来源是**只读**的(`docs/QUARK_API.md` §9),所以没有「按 TMDB 重命名」之类的写操作。
/// - ⚠️ 登录凭据**不在这里改**:它所有夸克来源共用,改它的路是扫码。
struct QuarkSourceSettingsView: View {
    let container: AppContainer
    let source: QuarkSource

    @State private var displayName: String
    /// 编辑中的片库根(**保存时才写库**,与显示名同一批提交)。nil = 没设。
    @State private var root: QuarkLibraryRoot?
    @State private var savedDisplayName = ""
    @State private var savedRoot: QuarkLibraryRoot?

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showsDirectoryPicker = false
    @State private var showsSignOutConfirmation = false
    /// 已登录账号的昵称(读内存快照,不发请求)
    @State private var accountName: String?
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(container: AppContainer, source: QuarkSource) {
        self.container = container
        self.source = source
        _displayName = State(initialValue: source.displayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "qrcode",
                title: "夸克网盘",
                subtitle: "片库根决定进来时先落在哪个目录。这个来源只读:"
                    + "可以浏览与播放,不能修改网盘里的文件。"
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
            QuarkDirectoryPickerView(container: container) { path in
                root = QuarkLibraryRoot(path: path, name: (path as NSString).lastPathComponent)
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
            Text("清除本机保存的夸克登录凭据,回到扫码那一屏。"
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
            TextField("名称", text: $displayName, prompt: Text("夸克网盘"))
                .autocorrectionDisabled()
        } header: {
            Text("名称")
        } footer: {
            Text("显示在来源列表与工具栏的来源菜单里。有多个夸克来源时,"
                + "起个能区分的名字(例如「夸克网盘 · 电影」)。")
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
            LabeledContent("账号") {
                Text(accountName ?? "已登录")
                    .foregroundStyle(accountName == nil ? .secondary : .primary)
            }
            Button("退出登录", role: .destructive) {
                showsSignOutConfirmation = true
            }
        } header: {
            Text("登录")
        } footer: {
            Text("登录是**所有夸克来源共用**的:退出之后,每个夸克来源都会回到扫码那一屏。"
                + "重新扫码会用同一套设备指纹换新凭据。")
        }
    }

    // MARK: - 动作

    private func load() async {
        do {
            root = try await container.quarkLibraryRoot(for: source)
            savedRoot = root
            errorMessage = nil
        } catch {
            errorMessage = "读取片库根失败:\(error)"
        }
        // 只读内存快照,不发请求:昵称是扫码那时取回来的一格。
        accountName = await container.quarkAccount()?.nickname
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
                    try await container.setQuarkLibraryRoot(root, for: source)
                }
                let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != savedDisplayName {
                    try await container.renameQuarkSource(source, displayName: trimmed)
                }
                dismiss()
            } catch let error as QuarkError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = "保存失败:\(error)"
            }
            isSaving = false
        }
    }

    private func signOut() async {
        do {
            try await container.signOutQuark()
            dismiss()
        } catch {
            errorMessage = "退出登录失败:\(error)"
        }
    }
}
