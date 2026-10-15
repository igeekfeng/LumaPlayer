import SwiftUI

/// 首页顶部的 hero:一项内容的整宽背景图 + 标题(有 Logo 用 Logo)+ 继续播放 / 详情。
///
/// 选哪一项见 `HomeViewModel.heroPick`(继续观看优先,其次各库最新),数据全部来自首页
/// 已经加载的行,⛔ 不为 hero 另发列表请求,⛔ 不轮播(轮播要么多发图片请求,要么换图时首屏跳)。
///
/// 图层自下而上:
/// 1. 模糊放大的海报(`heroBackdropBlur` / `heroBackdropScale`,与百度详情页 hero 同一做法)——
///    背景图取不到时的退路:有的服务器在 `BackdropImageTags` 里回填 `Primary` 的 tag,
///    请求 Backdrop 直接 404(`EmbyItem.coverImageFallback` 的注释);
/// 2. 背景图本身,取不到就透明(露出第 1 层),⛔ 不画灰色占位;
/// 3. 左侧黑色压暗(文字区)+ 底部渐变到窗口底色(与下面的货架接上)。
///
/// 文字固定深色外观(白字):它永远压在压暗过的图上,与系统深浅色无关。
/// ⛔ 不从图里取色做 tint(DesignTokens.swift「界面规则」)。
struct HomeHero: View {
    let item: EmbyItem
    let serverID: UUID
    let store: PosterImageStore
    let onPlay: () -> Void
    let onOpenDetail: () -> Void

    @State private var width: CGFloat = 0
    /// Logo 取不到(或没有)时用文字标题
    @State private var isLogoUnavailable = false

    /// hero 高度:按宽度算,夹在上下限之间(窗口很宽时不至于占满一屏,很窄时不至于扁成一条)
    static func height(forWidth width: CGFloat) -> CGFloat {
        min(max(width * Metrics.homeHeroHeightRatio, Metrics.homeHeroMinHeight), Metrics.homeHeroMaxHeight)
    }

    var body: some View {
        let height = Self.height(forWidth: width)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay { artwork }
            .clipped()
            .overlay { scrims }
            // 点图本身进详情(按钮之外的地方)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenDetail)
            .overlay(alignment: .bottomLeading) {
                info
                    .padding(.horizontal, Metrics.spacingXL)
                    .padding(.bottom, height * Metrics.homeHeroInfoBottomFraction)
                    .environment(\.colorScheme, .dark)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("精选:\(title)")
    }

    // MARK: - 图层

    private var artwork: some View {
        ZStack {
            if let posterSpec {
                PosterImage(spec: posterSpec, store: store, showsPlaceholder: false)
                    .blur(radius: Metrics.heroBackdropBlur)
                    .scaleEffect(Metrics.heroBackdropScale)
            } else {
                Color.black
            }
            PosterImage(spec: backdropSpec, store: store, showsPlaceholder: false)
        }
        .accessibilityHidden(true)
    }

    private var scrims: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(Metrics.homeHeroSideScrimOpacity), .clear],
                startPoint: .leading,
                endPoint: UnitPoint(x: Metrics.homeHeroSideScrimEnd, y: 0.5)
            )
            LinearGradient(
                stops: [
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0), location: Metrics.homeHeroBottomFadeStart),
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - 文字与按钮

    private var info: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingM) {
            titleView
            if let subtitle {
                Text(subtitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            if let meta {
                Text(meta)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let progress = item.progressFraction {
                HStack(spacing: Metrics.spacingS) {
                    CardProgressBar(fraction: progress)
                        .frame(width: Metrics.homeHeroProgressWidth)
                    if let remaining = MediaFormat.remaining(for: item) {
                        Text(remaining)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            actions
                .padding(.top, Metrics.spacingXS)
        }
        .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private var titleView: some View {
        if let logoSpec, !isLogoUnavailable {
            PosterImage(spec: logoSpec, store: store, showsPlaceholder: false) { loaded in
                if !loaded { isLogoUnavailable = true }
            }
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: Metrics.homeHeroLogoMaxWidth, maxHeight: Metrics.homeHeroLogoMaxHeight, alignment: .bottomLeading)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
        } else {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .shadow(color: .black.opacity(0.4), radius: Metrics.spacingS)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: Metrics.spacingM) {
            HStack(spacing: Metrics.spacingM) {
                if isPlayable {
                    Button(action: onPlay) {
                        Label(item.progressFraction == nil ? "播放" : "继续播放", systemImage: "play.fill")
                            .padding(.horizontal, Metrics.spacingS)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Button(action: onOpenDetail) {
                        Label("详情", systemImage: "info.circle")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                } else {
                    // 剧集本身不可直接播(要先定位到哪一集,那在详情页里)
                    Button(action: onOpenDetail) {
                        Label("查看详情", systemImage: "info.circle")
                            .padding(.horizontal, Metrics.spacingS)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    // MARK: - 数据

    private var isPlayable: Bool { item.kind == .movie || item.kind == .episode }

    /// 分集显示剧名(副标题是「S1E3 · 集名」),其余显示自己的名字
    private var title: String {
        item.kind == .episode ? (item.seriesName ?? item.name) : item.name
    }

    private var subtitle: String? {
        guard item.kind == .episode else { return nil }
        return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }

    /// 电影 / 剧集:年份 · 片长
    private var meta: String? {
        guard item.kind != .episode else { return nil }
        let parts = [
            item.productionYear.map(String.init),
            MediaFormat.runtime(ticks: item.runTimeTicks),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var backdropSpec: ImageSpec? {
        item.backdropSource.map {
            ImageSpec(serverID: serverID, itemID: $0.itemID, type: .backdrop, tag: $0.tag,
                      maxWidth: Int(Metrics.homeHeroImageMaxWidth))
        }
    }

    /// 模糊底图用自己的海报;档位与海报卡片一致(`MediaCard`),通常直接命中图片缓存
    private var posterSpec: ImageSpec? {
        item.primaryImageTagValue.map {
            ImageSpec(serverID: serverID, itemID: item.id, type: .primary, tag: $0,
                      maxWidth: Int(Metrics.posterMinWidth * 2))
        }
    }

    /// 分集用剧的 Logo(`logoSource` 自带父级回退)
    private var logoSpec: ImageSpec? {
        item.logoSource.map {
            ImageSpec(serverID: serverID, itemID: $0.itemID, type: .logo, tag: $0.tag,
                      maxWidth: Int(Metrics.homeHeroLogoMaxWidth * 2))
        }
    }
}
