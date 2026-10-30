import SwiftUI

/// 播放选项(⋯):低频播放偏好,与菜单栏「Playback」里的对应项同一份状态。
///
/// 首页是开关 + 翻页入口,章节 / 版本 / 画面 / 片头片尾各占一页(形态见 `PlayerPanelKind`)。
/// 页面状态在面板里,收起再打开回到首页。
struct PlayerOptionsPanel: View {
    @Bindable var viewModel: PlayerViewModel
    let dismiss: () -> Void
    /// sheet 由播放窗口呈现,这里只负责打开
    let openMarkersEditor: () -> Void

    private enum Page {
        case home
        case chapters
        case versions
        case picture
        case markers
    }

    @State private var page = Page.home

    var body: some View {
        PlayerPanelChrome(title: "播放选项") {
            switch page {
            case .home: home
            case .chapters: chapters
            case .versions: versions
            case .picture: picture
            case .markers: markers
            }
        }
    }

    // MARK: 首页

    @ViewBuilder
    private var home: some View {
        PlayerPanelToggleRow(title: "自动跳过片头", isOn: $viewModel.autoSkipIntro)
        PlayerPanelToggleRow(title: "自动播放下一集", isOn: $viewModel.autoPlayNext)

        PlayerPanelSeparator()

        if viewModel.hasChapters {
            PlayerPanelRow(
                title: "章节", systemImage: "list.bullet.indent", value: currentChapterName, opensPage: true
            ) { page = .chapters }
        }
        if viewModel.versionOptions.count > 1 {
            PlayerPanelRow(
                title: "版本", systemImage: "square.stack", value: currentVersionLabel, opensPage: true
            ) { page = .versions }
        }
        PlayerPanelRow(
            title: "画面", systemImage: "aspectratio",
            value: viewModel.isPictureAdjusted ? "已调整" : nil, opensPage: true
        ) { page = .picture }
            .disabled(viewModel.session == nil)
        PlayerPanelRow(
            title: "片头片尾", systemImage: "forward.end",
            value: viewModel.hasManualMarkers ? "已设置" : nil, opensPage: true
        ) { page = .markers }

        PlayerPanelSeparator()

        PlayerPanelToggleRow(title: "窗口置顶", isOn: $viewModel.floatsOnTop)
        PlayerPanelToggleRow(
            title: "显示统计信息",
            isOn: Binding(get: { viewModel.showsStatistics }, set: { _ in viewModel.toggleStatistics() }),
            help: "显示统计信息(I)")
    }

    private var currentChapterName: String? {
        viewModel.chapters.first { $0.id == viewModel.currentChapterID }?.displayName
    }

    private var currentVersionLabel: String? {
        viewModel.versionOptions.first { $0.id == viewModel.session?.mediaSource.id }?.versionLabel
    }

    // MARK: 章节

    /// 容器章节(Emby / 百度 / 本地统一由 mpv 给)。
    ///
    /// 跳转走 `viewModel.seekToChapter` 而不是 mpv 的 `chapter` 属性:转码流必须由客户端重新起流。
    @ViewBuilder
    private var chapters: some View {
        PlayerPanelBackHeader(title: "章节") { page = .home }
        PlayerPanelList(rowCount: viewModel.chapters.count) {
            ForEach(viewModel.chapters) { chapter in
                PlayerPanelRow(
                    title: chapter.displayName,
                    detail: PlayerTime.markerText(chapter.time),
                    isSelected: chapter.id == viewModel.currentChapterID
                ) { viewModel.seekToChapter(chapter) }
            }
        }
        .disabled(!viewModel.canSkipChapter)
    }

    // MARK: 版本

    /// 同一部片的多版本。切换 = 从当前位置重新起流。
    @ViewBuilder
    private var versions: some View {
        PlayerPanelBackHeader(title: "版本") { page = .home }
        PlayerPanelList(rowCount: viewModel.versionOptions.count) {
            ForEach(viewModel.versionOptions, id: \.id) { source in
                PlayerPanelRow(
                    title: source.versionLabel,
                    isSelected: source.id == viewModel.session?.mediaSource.id
                ) { viewModel.selectVersion(source.id) }
            }
        }
    }

    // MARK: 画面

    /// 画面适配:填充 / 宽高比 / 缩放 / 旋转(MPV_INTEGRATION.md 7.4)。
    /// 都是「针对这一集源」的临时修正,所以不给持久化,换片回到自动。
    @ViewBuilder
    private var picture: some View {
        PlayerPanelBackHeader(title: "画面") { page = .home }

        PlayerPanelHeader(title: "比例")
        HStack(spacing: Metrics.spacingXS) {
            ForEach(PictureSettings.Fit.allCases) { fit in
                choiceChip(Self.shortName(fit), help: fit.displayName, isSelected: viewModel.picture.fit == fit) {
                    viewModel.setPictureFit(fit)
                }
            }
        }

        PlayerPanelHeader(title: "宽高比")
        HStack(spacing: Metrics.spacingXS) {
            ForEach(PictureSettings.Aspect.allCases) { aspect in
                choiceChip(
                    Self.shortName(aspect), help: aspect.displayName, isSelected: viewModel.picture.aspect == aspect
                ) { viewModel.setPictureAspect(aspect) }
            }
        }

        PlayerPanelHeader(title: "缩放")
        PlayerPanelStepper(
            value: "\(viewModel.picture.zoomPercent)%",
            decrementVerb: "缩小",
            incrementVerb: "放大",
            stepText: "一档",
            canDecrement: viewModel.picture.zoom > PictureSettings.zoomRange.lowerBound,
            canIncrement: viewModel.picture.zoom < PictureSettings.zoomRange.upperBound,
            isResetDisabled: viewModel.picture.zoom == 0,
            resetHelp: "缩放 100%",
            step: { up, _ in viewModel.stepPictureZoom(up: up) },
            reset: { viewModel.resetPictureZoom() }
        )

        PlayerPanelSeparator()

        PlayerPanelRow(
            title: "顺时针旋转 90°",
            systemImage: "rotate.right",
            value: viewModel.picture.rotation == 0 ? nil : "已旋转 \(viewModel.picture.rotation)°"
        ) { viewModel.rotatePicture() }
        PlayerPanelRow(title: "画面设置复位", systemImage: "arrow.counterclockwise") { viewModel.resetPicture() }
            .disabled(!viewModel.isPictureAdjusted)
    }

    private func choiceChip(
        _ title: String, help: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: Metrics.playerPanelChipHeight)
        }
        .buttonStyle(PlayerPanelButtonStyle(shape: .tile, isSelected: isSelected))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 档位按钮放不下 `displayName` 全文,全文进 tooltip
    private static func shortName(_ fit: PictureSettings.Fit) -> String {
        switch fit {
        case .automatic: "适应"
        case .fill: "填满裁边"
        }
    }

    private static func shortName(_ aspect: PictureSettings.Aspect) -> String {
        switch aspect {
        case .automatic: "自动"
        case .widescreen, .standard: aspect.displayName
        }
    }

    // MARK: 片头片尾

    /// 手动片头 / 片尾,同一部剧共用(`ManualMarkersScope`)。
    ///
    /// ⛔ 这里不要读 `viewModel.positionSeconds`:每 0.2s 变一次,整个面板跟着重绘、悬停高亮会闪。
    /// 打点的秒数由点击后的屏显给出。
    @ViewBuilder
    private var markers: some View {
        PlayerPanelBackHeader(title: "片头片尾") { page = .home }
        if let summary = viewModel.manualMarkerValues?.summary {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.spacingS)
                .padding(.vertical, Metrics.spacingXS)
        }
        PlayerPanelHeader(title: "以当前位置")
        PlayerPanelRow(title: "设为片头起点", systemImage: "arrow.right.to.line") {
            viewModel.setIntroStartAtCurrentPosition()
        }
        PlayerPanelRow(title: "设为片头终点", systemImage: "arrow.left.to.line") {
            viewModel.setIntroEndAtCurrentPosition()
        }
        PlayerPanelRow(title: "设为片尾起点", systemImage: "flag.checkered") {
            viewModel.setCreditsStartAtCurrentPosition()
        }

        PlayerPanelSeparator()

        PlayerPanelRow(title: "手动输入…", systemImage: "keyboard") {
            dismiss()
            openMarkersEditor()
        }
        PlayerPanelRow(title: "清除本剧的片头片尾", systemImage: "trash", isDestructive: true) {
            viewModel.clearManualMarkers()
        }
        .disabled(!viewModel.hasManualMarkers)
    }
}
