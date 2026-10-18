import SwiftUI

/// 勾选分集批量标记已看 / 未看(API_CONTRACT.md 5.8)。
///
/// 为什么要有这个面板:详情页的 ✓ 只作用于一项(剧集 = 整部剧,分集 = 那一集),
/// 而「播放记录被重置后补标」往往既不是整部剧、也不是一集 —— 比如「第 1 季前 6 集看过」。
/// 面板把当前这一季的分集摆成可勾选的清单,默认勾上**还没到目标状态**的那些
/// (已经标好的不必再发一次请求),再一次性提交。
///
/// Emby 没有批量端点,提交是逐条串行发的(5.8),所以应用后面板先关掉,
/// 进度显示在分集区的标题行上,不在这里再挂一层等待。
struct SeasonPlayedPickerSheet: View {
    /// 当前这一季的分集(已加载的列表,不在这里发请求)
    let episodes: [EmbyItem]
    /// 季名,只用于标题
    let seasonName: String
    /// 默认目标:已看的集多就默认「标记为未看」,否则默认「标记为已看」
    @State private var played: Bool
    @State private var selectedIDs: Set<String>
    var onApply: ([String], Bool) -> Void
    var onClose: () -> Void

    init(episodes: [EmbyItem], seasonName: String, onApply: @escaping ([String], Bool) -> Void, onClose: @escaping () -> Void) {
        self.episodes = episodes
        self.seasonName = seasonName
        self.onApply = onApply
        self.onClose = onClose
        let playedCount = episodes.filter(\.isPlayed).count
        let target = playedCount * 2 < episodes.count
        _played = State(initialValue: target)
        _selectedIDs = State(initialValue: Set(episodes.filter { $0.isPlayed != target }.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(Metrics.spacingXL)
            Divider()
            targetPicker
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.vertical, Metrics.spacingM)
            Divider()
            selectionBar
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.vertical, Metrics.spacingS)
            episodeList
                .frame(height: listHeight)
            Divider()
            footer
                .padding(Metrics.spacingXL)
        }
        .frame(width: Metrics.playedPickerWidth)
    }

    // MARK: - 版块

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text("批量标记「\(seasonName)」")
                    .font(.headline)
                Text("勾选要改的分集,再统一提交。已经处于目标状态的集默认不勾 —— 不重复发请求。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var targetPicker: some View {
        Picker("标记为", selection: $played) {
            Text("已看").tag(true)
            Text("未看").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: played) { _, newValue in
            // 换目标就重算默认勾选:上一个目标下勾好的集对新目标没有意义
            selectedIDs = Set(episodes.filter { $0.isPlayed != newValue }.map(\.id))
        }
        .accessibilityLabel("标记为")
    }

    private var selectionBar: some View {
        HStack(spacing: Metrics.spacingM) {
            Text("已选 \(selectedIDs.count) / \(episodes.count) 集")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("全选") { selectedIDs = Set(episodes.map(\.id)) }
            Button("仅未看") { selectedIDs = Set(episodes.filter { !$0.isPlayed }.map(\.id)) }
            Button("全不选") { selectedIDs = [] }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private var episodeList: some View {
        List(episodes) { episode in
            Toggle(isOn: binding(for: episode.id)) {
                HStack(spacing: Metrics.spacingS) {
                    Text(label(for: episode))
                        .lineLimit(1)
                    if episode.isPlayed {
                        Label("已看", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("当前已看")
                    }
                }
            }
            .toggleStyle(.checkbox)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: Metrics.spacingM) {
            Text(played ? "将标记为已看" : "将标记为未看")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消", action: onClose)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button(applyTitle) {
                // 只提交「还不在目标状态」的集:勾了已经标好的那些是空写
                let ids = episodes.filter { selectedIDs.contains($0.id) && $0.isPlayed != played }.map(\.id)
                onApply(ids, played)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(applicableIDs.isEmpty)
        }
    }

    // MARK: - 内部

    /// 清单高度按行数算,并封顶到 `playedPickerListMaxHeight`。
    ///
    /// `List` 在弹性容器里会**按容器高度硬裁**(2026-10-18 截图:5 集的季把第 5 行
    /// 裁掉一半),而给固定高度又会让集少的季下方空一大片。行高是固定的,
    /// 所以直接算:一行 = `playedPickerRowHeight` + `spacingXXS` 的列表内边距。
    private var listHeight: CGFloat {
        let rows = CGFloat(episodes.count)
        let estimated = rows * (Metrics.playedPickerRowHeight + Metrics.spacingXXS) + Metrics.spacingM
        return min(max(estimated, Metrics.playedPickerRowHeight * 2), Metrics.playedPickerListMaxHeight)
    }

    private var applicableIDs: [String] {
        episodes.filter { selectedIDs.contains($0.id) && $0.isPlayed != played }.map(\.id)
    }

    private var applyTitle: String {
        applicableIDs.isEmpty
            ? "没有要改的分集"
            : "\(played ? "标记为已看" : "标记为未看")(\(applicableIDs.count))"
    }

    /// 「3. 集名」;集号来自服务端,没有就只显示集名(与分集卡片同一口径,不猜不占位)。
    private func label(for episode: EmbyItem) -> String {
        guard let index = episode.indexNumber else { return episode.name }
        return "\(index). \(episode.name)"
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
            }
        )
    }
}
