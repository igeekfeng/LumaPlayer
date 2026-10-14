import SwiftUI

/// 从网盘里挑一个目录作为片库根(`BaiduPanSourceSettingsView` 的「从网盘添加…」)。
///
/// ⚠️ 只列**目录**(片库根只能是目录),而且**一次只列一层** —— 每进一层发一次
/// `list` 请求,不预取子树(配额见 `docs/BAIDU_PAN_API.md` §7)。
/// 起点固定是应用目录 `/apps/{应用目录名}`,⛔ 退不出去:那以外第三方应用访问不到。
struct BaiduPanDirectoryPickerView: View {
    let container: AppContainer
    /// 选中一个目录(完整路径)。
    let onPick: (String) -> Void

    @State private var rootDirectory: String?
    @State private var currentDirectory: String?
    @State private var folders: [BaiduPanFile] = []
    @State private var isLoading = true
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Metrics.onboardingFormWidth, height: Self.windowHeight)
        .task { await loadRoot() }
    }

    private static let windowHeight: CGFloat = 460

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: Metrics.spacingS) {
            Text("选择片库根目录")
                .font(.title3.weight(.semibold))
            Text(relativePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingM)
    }

    /// 相对应用目录的路径(应用目录本身显示 `/`)。
    private var relativePath: String {
        guard let current = currentDirectory else { return "/" }
        guard let root = rootDirectory else { return current }
        if current == root { return "/" }
        guard current.hasPrefix(root) else { return current }
        let remainder = String(current.dropFirst(root.count))
        return remainder.isEmpty ? "/" : remainder
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在读取目录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            VStack(spacing: Metrics.spacingM) {
                OnboardingNotice(text: failure, style: .error)
                Button("重试") { Task { await load(currentDirectory) } }
            }
            .padding(Metrics.spacingXL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if folders.isEmpty {
            ContentUnavailableView {
                Label("这一层没有子目录", systemImage: "folder")
            } description: {
                Text("可以直接把当前目录设为片库根,或者退回去换一层。")
            }
        } else {
            List(folders) { folder in
                Button {
                    Task { await load(folder.path) }
                } label: {
                    HStack(spacing: Metrics.spacingM) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.tint)
                        Text(folder.name)
                            .lineLimit(1)
                        Spacer(minLength: Metrics.spacingM)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: Metrics.spacingM) {
            Button("返回上一层") {
                Task { await goUp() }
            }
            .disabled(!canGoUp || isLoading)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("选这个目录") {
                guard let current = currentDirectory else { return }
                onPick(current)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentDirectory == nil || isLoading)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingM)
    }

    private var canGoUp: Bool {
        guard let current = currentDirectory, let root = rootDirectory else { return false }
        return current != root
    }

    // MARK: - 动作

    private func loadRoot() async {
        do {
            let root = try await container.baiduConnection().applicationDirectory()
            rootDirectory = root
            await load(root)
        } catch let error as BaiduPanError {
            failure = error.userMessage
            isLoading = false
        } catch {
            failure = "读取应用目录失败:\(error)"
            isLoading = false
        }
    }

    private func load(_ directory: String?) async {
        guard let directory else { return }
        isLoading = true
        failure = nil
        do {
            let files = try await container.baiduConnection().files(inDirectory: directory)
            // 只列目录:片库根只能是目录
            folders = files.filter(\.isDirectory)
            currentDirectory = directory
        } catch let error as BaiduPanError {
            failure = error.userMessage
        } catch {
            failure = "读取目录失败:\(error)"
        }
        isLoading = false
    }

    private func goUp() async {
        guard let current = currentDirectory, let root = rootDirectory,
              current != root else { return }
        let parent = (current as NSString).deletingLastPathComponent
        await load(parent.hasPrefix(root) ? parent : root)
    }
}
