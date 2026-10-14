import SwiftUI

/// 百度网盘来源的设置(设置 →「来源」→ 选中百度网盘 → 编辑…)。
///
/// ## 为什么这些动作在这里
///
/// 它们原本挤在浏览页顶部那条路径栏里(「设为片库根」「解除授权」)。
/// 那条栏已经去掉 —— 低频的配置动作不该占着每天看的页面
/// (DesignTokens.swift「界面规则」),所以搬进来源设置。
///
/// ## 与 `ServerSettingsView`(Emby)的关系
///
/// 同形:sheet + `OnboardingFormHeader` + `Form` + `OnboardingActionBar`。
/// 差别在内容:Emby 改的是地址(要重新探测),这里改的是**显示名**与**片库根**。
///
/// ⚠️ 授权与密钥**不在这里改**:它们是所有百度来源共用的、且改 AppKey 会作废 token
/// (`BaiduPanConnection.saveConfiguration`),那条路仍在授权页
/// (`BaiduPanAuthorizationView`)。
struct BaiduPanSourceSettingsView: View {
    let container: AppContainer
    let source: BaiduPanSource

    /// 编辑中的显示名
    @State private var displayName: String
    /// 编辑中的片库根(**保存时才写库** —— 与显示名同一批提交)。nil = 没设。
    @State private var root: BaiduPanLibraryRoot?
    /// 磁盘上的现值(判断有没有改,没改就不发写请求)
    @State private var savedDisplayName = ""
    @State private var savedRoot: BaiduPanLibraryRoot?

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showsDirectoryPicker = false
    @State private var showsSignOutConfirmation = false
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(container: AppContainer, source: BaiduPanSource) {
        self.container = container
        self.source = source
        _displayName = State(initialValue: source.displayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "cloud.fill",
                title: "百度网盘",
                subtitle: "片库根决定进来时先落在哪个目录。一个来源一个 ——"
                    + "想再要一个起点,就在来源列表里再加一个百度来源。"
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
            BaiduPanDirectoryPickerView(container: container) { path in
                root = BaiduPanLibraryRoot(path: path)
            }
        }
        .confirmationDialog(
            "解除授权",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("解除授权", role: .destructive) { Task { await signOut() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除本机保存的百度授权,回到扫码那一屏。"
                + "AppKey / 密钥与片库根都保留 —— 重新扫码即可继续用。")
        }
    }

    /// 表单本身不长,给一个够用的固定高度(与 `ServerSettingsView` 同一口径)。
    private static let windowHeight: CGFloat = 420

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
            TextField("名称", text: $displayName, prompt: Text("百度网盘"))
                .autocorrectionDisabled()
        } header: {
            Text("名称")
        } footer: {
            Text("显示在来源列表与工具栏的来源菜单里。有多个百度来源时,"
                + "起个能区分的名字(例如「百度网盘 · 电影」)。")
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
                        .help("不再固定起点,进来时落在应用目录")
                }
            } else {
                Text("还没有片库根,进来时会落在应用目录 /apps/\(source.folderName)。")
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
            Text("片库根是应用目录**内部**的一个起点目录(例如 apps/LumaPlayer/Videos)。"
                + "它只是「从哪开始」的书签,不影响授权范围;"
                + "浏览页也不会退到它之上 —— 它就是那一页的最外层。")
        }
    }

    private var authorizationSection: some View {
        Section {
            Button("解除授权", role: .destructive) {
                showsSignOutConfirmation = true
            }
        } header: {
            Text("授权")
        } footer: {
            Text("授权是**所有百度来源共用**的:解除之后,每个百度来源都会回到扫码那一屏。")
        }
    }

    // MARK: - 动作

    private func load() async {
        do {
            root = try await container.libraryRoot(for: source)
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
                    try await container.setLibraryRoot(root?.path, for: source)
                }
                let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != savedDisplayName {
                    try await container.renameBaiduSource(source, displayName: trimmed)
                }
                dismiss()
            } catch let error as BaiduPanError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = "保存失败:\(error)"
            }
            isSaving = false
        }
    }

    private func signOut() async {
        do {
            try await container.signOutBaidu()
            dismiss()
        } catch {
            errorMessage = "解除授权失败:\(error)"
        }
    }
}
