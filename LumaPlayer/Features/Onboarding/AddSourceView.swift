import SwiftUI

/// 添加**播放来源**的第一屏:先选来源类型,再进具体表单。
///
/// 这是本次改造的入口形态 —— ⛔ 不是「Emby 表单 + 一个侧门按钮」,
/// 而是「来源是一层,Emby 与百度网盘是它的两个实现」
/// (`docs/SOURCE_ABSTRACTION_PLAN.md` §0)。
///
/// 两种使用场景:
/// - 首次启动的引导页(无取消按钮 —— 没有可返回的地方);
/// - 设置窗口「来源」标签页里的 +(sheet,有取消按钮)。
struct AddSourceView: View {
    let container: AppContainer

    @State private var selection: SourceKind?

    private let showsCancelButton: Bool

    @MainActor
    init(container: AppContainer, showsCancelButton: Bool = false) {
        self.container = container
        self.showsCancelButton = showsCancelButton
    }

    var body: some View {
        Group {
            switch selection {
            case .none:
                chooser
            case .some(.emby):
                AddServerView(
                    container: container,
                    showsCancelButton: false,
                    onBack: { selection = nil }
                )
            case .some(.baiduPan):
                BaiduPanAddView(
                    container: container,
                    onBack: { selection = nil },
                    onDone: onFinish
                )
            case .some(.localFolder):
                LocalFolderAddView(
                    container: container,
                    onBack: { selection = nil },
                    onDone: onFinish
                )
            }
        }
    }

    // MARK: - 选类型

    private var chooser: some View {
        VStack(spacing: 0) {
            OnboardingFormHeader(
                systemImage: "rectangle.stack.badge.plus",
                title: "添加播放来源",
                subtitle: "选择要从哪里播放。Emby 服务器、百度网盘与本地文件夹可以同时存在,随时切换。"
            )

            VStack(spacing: Metrics.spacingM) {
                ForEach(SourceKind.allCases) { kind in
                    Button {
                        selection = kind
                    } label: {
                        HStack(spacing: Metrics.spacingM) {
                            Image(systemName: kind.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: Metrics.serverRowIconSize)
                            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                                Text(kind.title)
                                    .font(.headline)
                                Text(kind.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: Metrics.spacingM)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(Metrics.spacingL)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.card))
                }
            }
            .frame(width: Metrics.onboardingFormWidth)
            .padding(.horizontal, Metrics.spacingXL)
            .padding(.top, Metrics.spacingL)

            Spacer(minLength: Metrics.spacingL)

            if showsCancelButton {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .padding(.bottom, Metrics.spacingXL)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    @Environment(\.dismiss) private var dismiss

    /// 子流程完成(百度授权成功 / 本地文件夹选好,并已落库):切来源已经在容器里做掉了,
    /// 这里只负责把这一 sheet 关掉。
    private func onFinish() {
        dismiss()
    }
}

/// 可选来源类型。新增来源 = 加一个 case,编译器会逼你处理所有分支。
enum SourceKind: String, CaseIterable, Identifiable, Hashable {
    case emby
    case baiduPan
    case localFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emby: return "Emby 服务器"
        case .baiduPan: return "百度网盘"
        case .localFolder: return "本地文件夹"
        }
    }

    var subtitle: String {
        switch self {
        case .emby: return "连接到自建的 Emby / Jellyfin 兼容服务器。"
        case .baiduPan: return "播放开放平台应用目录下的网盘文件。"
        case .localFolder: return "播放本机、外接盘或已挂载网络卷上某个文件夹里的视频。"
        }
    }

    var symbol: String {
        switch self {
        case .emby: return "server.rack"
        case .baiduPan: return "cloud.fill"
        case .localFolder: return "folder.fill"
        }
    }
}
