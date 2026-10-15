import SwiftUI

/// 首页顶部的 hero:**一项**内容的整宽背景图 + 标题(有 Logo 用 Logo)+ 播放按钮。
///
/// 按钮只有一个,而且只有电影 / 分集才有;「进详情」靠**点整块画面**
/// (剧集的 hero 因此一个按钮都没有,见 `actions` 的注释)。
///
/// 这里只负责「渲染一项」。轮播(自动切换 / 箭头 / 圆点 / 预取下一张背景图)
/// 在 `HomeHeroCarousel`,它按顺序把这一项换成下一项 —— 分开是为了让本视图保持
/// 「输入一项、画一项」,定时器与选取状态不进这里。
///
/// 选哪几项见 `HomeViewModel.heroPick`(随机推荐优先,拿不到图才退回
/// 「继续观看 → 各库最新」),数据全部来自首页已经加载的行,
/// ⛔ 不为 hero 另发列表请求。
///
/// ⚠️ 这里以前写死「⛔ 不轮播」,理由是「多发图片请求 / 换图时首屏跳」。
/// 2026-10-15 核对:「首屏跳」不成立(`height(forWidth:)` 是按宽度算的固定值,
/// 换图不改布局),只剩图片请求一条代价,已由轮播层的预取按住。理由与取舍
/// 记在 `HomeHeroCarousel` 的类型注释里,⛔ 别把旧注释抄回来。
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
            // 点图本身进详情 —— 这是**唯一**的「进详情」入口(2026-10-15 起没有详情按钮了)
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
            // 鼠标那条路是「点画面」,辅助功能看不见画面 —— 动作得单独给
            .accessibilityAction(named: Text("查看详情")) { onOpenDetail() }
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
            // 只有电影 / 分集能直接播;剧集要先进详情定位到哪一集,所以这里什么都不给
            if isPlayable {
                playButton
                    .padding(.top, Metrics.spacingXS)
            }
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

    /// 唯一的按钮:「播放 / 继续播放」。调用方用 `if isPlayable` 挡着(见 `info`)。
    ///
    /// ⛔ 不再有「详情 / 查看详情」按钮(2026-10-15 用户要求去掉):hero 整块本来就是可点的
    /// (根视图的 `.contentShape` + `onTapGesture(onOpenDetail)`),再来一个按钮只是把
    /// 一个已经存在的动作画第二遍;而且在剧集上它是**唯一**的按钮、铺成一整条横排,
    /// 压在标题旁边很难看。进详情这条路只保留「点画面」。
    /// 无障碍那边补了同名的 `accessibilityAction`(见 `body`),⛔ 别让辅助功能
    /// 因为少了一个按钮就丢掉这条路径。
    ///
    /// ⚠️ 剧集的 hero 因此**一个按钮都没有** —— 有意为之:它确实没有「直接播」这个动作
    /// (要先在详情页里定位到哪一集),而「看详情」点画面即可。
    private var playButton: some View {
        GlassEffectContainer(spacing: Metrics.spacingM) {
            Button(action: onPlay) {
                Label(item.progressFraction == nil ? "播放" : "继续播放", systemImage: "play.fill")
                    .padding(.horizontal, Metrics.spacingS)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
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
