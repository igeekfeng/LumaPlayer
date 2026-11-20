import SwiftUI

/// 从夸克网盘里挑一个目录作为片库根(`QuarkSourceSettingsView` 的「从网盘选择…」)。
///
/// 与另外两家同形,差别只在起点:夸克 TV 端能读整个网盘,起点就是网盘根 `"/"`。
/// ⚠️ 一次一层,点得再快也是一次一层(串行限速,`docs/QUARK_API.md` §5)。
struct QuarkDirectoryPickerView: View {
    let container: AppContainer
    /// 选中一个目录(从网盘根算起的虚拟路径)
    let onPick: (String) -> Void

    @State private var currentDirectory: String?
    /// 子目录(只列目录:picker 只需要路径与名字,⛔ 不建 `BaiduPanFile`)
    @State private var folders: [Folder] = []
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
        .task { await load(QuarkLibraryRoot.root.path) }
    }

    private static let windowHeight: CGFloat = 460

    struct Folder: Identifiable, Sendable, Equatable {
        let path: String
        let name: String
        var id: String { path }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: Metrics.spacingS) {
            Text("选择片库根目录")
                .font(.title3.weight(.semibold))
            Text(currentDirectory ?? QuarkPath.root)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingM)
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

    /// 网盘根之上没有东西,⛔ 不要退到 `""`(那会被归一化成根,看起来像没反应)。
    private var canGoUp: Bool {
        guard let current = currentDirectory else { return false }
        return current != QuarkLibraryRoot.root.path
    }

    // MARK: - 动作

    private func load(_ directory: String?) async {
        guard let directory else { return }
        isLoading = true
        failure = nil
        do {
            let entries = try await container.quarkConnection().files(in: directory)
            folders = entries
                .filter(\.isDirectory)
                .map { Folder(path: QuarkPath.child($0.name, of: directory), name: $0.name) }
            currentDirectory = directory
        } catch let error as QuarkError {
            failure = error.userMessage
        } catch {
            failure = "读取目录失败:\(error)"
        }
        isLoading = false
    }

    private func goUp() async {
        guard let current = currentDirectory, canGoUp else { return }
        await load(QuarkPath.parent(of: current))
    }
}
