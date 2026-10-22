import AppKit
import SwiftUI

/// 手动选择弹幕库:上半是 `/match` 的模糊候选,下半是关键词搜索(`/search/episodes`)。
/// 选定后记住这一集与这一部剧(`DanmakuBindingStore`),同剧其它集按集号自动对上。
///
/// ⛔ 不做边输边搜:弹弹play 搜索接口有滥用检测(`docs/DANDANPLAY_API.md` §6)。
struct DanmakuPickerSheet: View {
    let controller: DanmakuController
    var onClose: () -> Void

    @State private var keyword: String
    @State private var episodeText: String
    @State private var groups: [DanmakuSearchGroup] = []
    @State private var hasMore = false
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var didSearch = false

    init(controller: DanmakuController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        _keyword = State(initialValue: controller.query.searchKeyword)
        _episodeText = State(initialValue: controller.query.episodeNumber.map(String.init) ?? "")
    }

    private var candidates: [DanmakuCandidate] {
        if case .needsSelection(let candidates) = controller.status { return candidates }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(Metrics.spacingXL)
            Divider()
            searchBar.padding(Metrics.spacingXL)
            Divider()
            results
                .frame(minHeight: 260, maxHeight: 420)
            Divider()
            footer.padding(Metrics.spacingXL)
        }
        .frame(width: 560)
        .background(Self.background)
        // 见 `PlayerMarkersEditor`
        .preferredColorScheme(.dark)
    }

    private static let background = Color(nsColor: NSColor(white: 0.12, alpha: 1))

    // MARK: - 版块

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            Image(systemName: "text.bubble")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text("选择弹幕")
                    .font(.headline)
                Text("弹幕来自弹弹play。选定后会记住这一集;同一部剧的其他集按集号自动对上。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: Metrics.spacingM) {
            TextField("作品标题(至少 2 个字)", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)
            TextField("集数", text: $episodeText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .onSubmit(search)
                .help("只看这一集;留空看全部")
            Button("搜索", action: search)
                .disabled(!canSearch)
        }
    }

    @ViewBuilder
    private var results: some View {
        List {
            if !candidates.isEmpty, !didSearch {
                Section("自动匹配的候选") {
                    ForEach(candidates) { candidate in
                        row(title: candidate.animeTitle, subtitle: candidate.episodeTitle,
                            detail: candidate.typeDescription) { choose(candidate) }
                    }
                }
            }
            if isSearching {
                HStack { ProgressView().controlSize(.small); Text("正在搜索…").foregroundStyle(.secondary) }
            } else if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if didSearch, groups.isEmpty {
                Text("没有搜到。换个标题(中文、日文、罗马音、英文都行)再试。")
                    .foregroundStyle(.secondary)
            }
            if hasMore {
                Text("结果太多,只显示了一部分。写得更具体一些可以缩小范围。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.episodes) { candidate in
                        row(title: candidate.episodeTitle, subtitle: nil, detail: nil) { choose(candidate) }
                    }
                } header: {
                    HStack {
                        Text(group.animeTitle ?? "作品 \(group.animeID)")
                        if let type = group.typeDescription {
                            Text(type).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func row(title: String?, subtitle: String?, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? "(无标题)")
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button("解除这一部的匹配", role: .destructive) {
                Task {
                    do {
                        try await controller.unbind()
                    } catch {
                        searchError = (error as? LocalizedError)?.errorDescription ?? "解除匹配失败"
                    }
                }
            }
            .disabled(controller.loaded == nil)
            .help("当前弹幕对不上时用:忘掉这一集与这一部剧记住的弹幕库")
            Spacer()
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 动作

    private var trimmedKeyword: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSearch: Bool { trimmedKeyword.count >= 2 && !isSearching }

    private func search() {
        guard canSearch else { return }
        let episode = Int(episodeText.trimmingCharacters(in: .whitespaces))
        isSearching = true
        searchError = nil
        didSearch = true
        Task {
            defer { isSearching = false }
            do {
                let result = try await controller.search(keyword: trimmedKeyword, episode: episode)
                groups = result.groups
                hasMore = result.hasMore
            } catch let error as DandanplayError {
                groups = []
                searchError = error.userMessage
            } catch {
                groups = []
                searchError = "搜索失败:\(error.localizedDescription)"
            }
        }
    }

    private func choose(_ candidate: DanmakuCandidate) {
        controller.select(candidate)
        onClose()
    }
}
