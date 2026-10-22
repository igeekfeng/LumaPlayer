import AppKit
import SwiftUI

/// 在线搜索字幕。骨架同 `DanmakuPickerSheet`。
///
/// - 打开就搜一次(assrt 配额 20 次/分钟)。⛔ 不做边输边搜。
/// - 点结果直接下载并挂上,不做二级文件列表:同一条字幕的多个文件由 `SubtitleService` 按格式优先级挑。
struct SubtitlePickerSheet: View {
    let viewModel: PlayerViewModel
    var onClose: () -> Void

    @State private var keyword: String
    @State private var results: [SubtitleSearchResult] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var errorText: String?
    /// 缺密钥时给去设置的入口
    @State private var needsToken = false
    /// 下载期间其它行禁用
    @State private var downloadingID: Int?

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    init(viewModel: PlayerViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        _keyword = State(initialValue: viewModel.subtitleSearchKeyword)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(Metrics.spacingXL)
            Divider()
            searchBar.padding(Metrics.spacingXL)
            Divider()
            resultsList
                .frame(minHeight: 280, maxHeight: 420)
            Divider()
            footer.padding(Metrics.spacingXL)
        }
        .frame(width: 600)
        .background(Self.background)
        // 见 `PlayerMarkersEditor`
        .preferredColorScheme(.dark)
        .task { searchIfPossible() }
    }

    private static let background = Color(nsColor: NSColor(white: 0.12, alpha: 1))

    // MARK: - 版块

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            Image(systemName: "captions.bubble")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text("搜索在线字幕")
                    .font(.headline)
                Text("从 assrt(伪射手)搜到的字幕会下载到本机,选中后立刻挂到当前视频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: Metrics.spacingM) {
            TextField("作品名(至少 3 个字)", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(searchIfPossible)
            Button("搜索", action: searchIfPossible)
                .disabled(!canSearch)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        List {
            if isSearching {
                HStack(spacing: Metrics.spacingS) {
                    ProgressView().controlSize(.small)
                    Text("正在搜索…").foregroundStyle(.secondary)
                }
            } else if let errorText {
                VStack(alignment: .leading, spacing: Metrics.spacingS) {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if needsToken {
                        Button("去设置里填密钥…") {
                            settingsTab = .subtitles
                            openSettings()
                            onClose()
                        }
                        .controlSize(.small)
                    }
                }
            } else if didSearch, results.isEmpty {
                Text("没有搜到。换个关键词(片名 / 剧名,中文或原名都行)再试。")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { result in
                row(result)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func row(_ result: SubtitleSearchResult) -> some View {
        Button {
            download(result)
        } label: {
            HStack(alignment: .top, spacing: Metrics.spacingM) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .lineLimit(2)
                    if let videoName = result.videoName {
                        Text(videoName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let detail = result.detailLine {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Metrics.spacingS)
                if downloadingID == result.id {
                    ProgressView().controlSize(.small)
                } else if let uploaded = result.uploadTime {
                    Text(uploaded.prefix(10))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil)
    }

    private var footer: some View {
        HStack(spacing: Metrics.spacingM) {
            // assrt 的归因要求:来源说明 + 本站链接
            Link(SubtitleService.attribution, destination: SubtitleService.attributionURL)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("设置…") {
                settingsTab = .subtitles
                openSettings()
            }
            .controlSize(.small)
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 动作

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSearch: Bool {
        trimmedKeyword.count >= AssrtEndpoint.minimumKeywordLength && !isSearching
    }

    private func searchIfPossible() {
        guard canSearch else { return }
        isSearching = true
        errorText = nil
        needsToken = false
        didSearch = true
        Task {
            defer { isSearching = false }
            do {
                results = try await viewModel.searchSubtitles(keyword: trimmedKeyword)
            } catch {
                results = []
                errorText = (error as? LocalizedError)?.errorDescription ?? "搜索失败:\(error.localizedDescription)"
                needsToken = (error as? AssrtError) == .missingToken
            }
        }
    }

    private func download(_ result: SubtitleSearchResult) {
        guard downloadingID == nil else { return }
        downloadingID = result.id
        errorText = nil
        Task {
            defer { downloadingID = nil }
            do {
                _ = try await viewModel.downloadSubtitle(result)
                onClose()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription
                    ?? "下载失败:\(error.localizedDescription)"
                needsToken = (error as? AssrtError) == .missingToken
            }
        }
    }
}
