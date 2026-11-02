import SwiftUI

/// 从 115 网盘里挑一个目录作为片库根(`Pan115SourceSettingsView` 的「从网盘选择…」)。
///
/// 与 `BaiduPanDirectoryPickerView` 同形,两处不同:
/// - 起点是**整个网盘根** `"/"`,没有应用目录那层限制(Cookie 能读全盘)。
/// - 只列目录,一次一层。⚠️ 115 有串行限速(`docs/PAN115_API.md` §6),点得再快也是一次一层。
struct Pan115DirectoryPickerView: View {
    let container: AppContainer
    /// 选中一个目录(从网盘根算起的路径)。
    let onPick: (String) -> Void

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
        .task { await load(Pan115LibraryRoot.root.path) }
    }

    private static let windowHeight: CGFloat = 460

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: Metrics.spacingS) {
            Text("选择片库根目录")
                .font(.title3.weight(.semibold))
            Text(currentDirectory ?? "/")
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
        return current != Pan115LibraryRoot.root.path
    }

    // MARK: - 动作

    private func load(_ directory: String?) async {
        guard let directory else { return }
        isLoading = true
        failure = nil
        do {
            let entries = try await container.pan115Connection().files(in: directory)
            folders = entries.compactMap { entry in
                guard entry.isDirectory else { return nil }
                return entry.file(parentPath: directory)
            }
            currentDirectory = directory
        } catch let error as Pan115Error {
            failure = error.userMessage
        } catch {
            failure = "读取目录失败:\(error)"
        }
        isLoading = false
    }

    private func goUp() async {
        guard let current = currentDirectory, canGoUp else { return }
        let parent = (current as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? Pan115LibraryRoot.root.path : parent)
    }
}
