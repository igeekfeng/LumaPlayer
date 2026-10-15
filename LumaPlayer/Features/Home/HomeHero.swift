import SwiftUI

/// 首页顶部的 hero:**一项**内容的整宽背景图 + 标题(Logo + 文字)+ 播放按钮。
///
/// 按钮只有一个「播放」(电影 / 分集 / 剧集都有,剧集播哪一集见 `playButton`);
/// 「进详情」靠**点整块画面**。
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
/// 布局:上面是**图片区**(`imageHeight(forWidth:)`),下面是一段**过渡带**(`homeHeroFadeBand`),
/// 合起来是 `height(forWidth:)`。
///
/// 图层自下而上:
/// 1. 模糊海报(`homeHeroFallbackBlur`)—— 背景图取不到时的退路,只当「色调」:
///    有的服务器在 `BackdropImageTags` 里回填 `Primary` 的 tag,请求 Backdrop 直接 404
///    (`EmbyItem.coverImageFallback` 的注释)。轮播里取不到背景图的项会被跳过
///    (`onBackdropUnavailable`),所以这一层通常只在「只剩这一项」时露出来;
/// 2. **同一张**背景图重度模糊后铺满整块(`homeHeroAmbientBlur`,含过渡带)—— 清晰图左边
///    空出来的地方与过渡带都靠它,颜色和清晰图连得上。同一 spec,命中图片缓存,不多发请求。
///    ⚠️ 模糊必须重:它是**整张图放大**铺的,模糊一轻就看得出和右边是同一批人物。
///    镜像接边、拉伸边缘一条都试过(2026-10-15),前者照样认得出人物、后者遇到自带黑边的图
///    接缝很难看,用户决定退回重度模糊;
/// 3. 清晰的背景图:按图片区高度**完整**摆放、靠右(宽 = 高 × 16:9,窗口更窄时才裁两侧),
///    左边缘与下边缘用渐变遮罩融进第 2 层。⛔ 不铺满整宽(会放大 + 裁掉上下四分之一,
///    `homeHeroImageAspect` 的注释);取不到就透明,⛔ 不画灰色占位;
/// 4. 左侧黑色压暗(只在图片区,过渡带里淡掉)+ 过渡带渐变到窗口底色(缓动曲线,不是线性)。
///    ⛔ 不在图片区底边硬切(太生硬),⛔ 不让清晰图直接线性淡成白雾(2026-10-15 两版的教训)。
///
/// 文字区:竖版小封面(仅电影 / 剧集)+ 标题(Logo 与文字同时出现,见 `titleView`)/ 元信息 / 两行简介 / 播放按钮。
/// 文字固定深色外观(白字):它永远压在压暗过的图上,与系统深浅色无关。
/// ⛔ 不从图里取色做 tint(DesignTokens.swift「界面规则」)。
struct HomeHero: View {
    let item: EmbyItem
    let serverID: UUID
    let store: PosterImageStore
    let onPlay: () -> Void
    /// 剧集正在定位要播的分集(按钮转圈、不可点,见 `HomeViewModel.playSeries`)
    var isResolvingPlayback = false
    let onOpenDetail: () -> Void
    /// 背景图试过且没拿到(轮播据此跳过这一项)
    var onBackdropUnavailable: () -> Void = {}

    @State private var width: CGFloat = 0
    /// Logo 取不到(或没有)时用文字标题
    @State private var isLogoUnavailable = false

    /// 图片区高度:按宽度算,夹在上下限之间(窗口很宽时不至于占满一屏,很窄时不至于扁成一条)
    static func imageHeight(forWidth width: CGFloat) -> CGFloat {
        min(max(width * Metrics.homeHeroHeightRatio, Metrics.homeHeroMinHeight), Metrics.homeHeroMaxHeight)
    }

    /// hero 总高 = 图片区 + 过渡带。只跟宽度有关,换图不改布局(轮播不跳的前提)
    static func height(forWidth width: CGFloat) -> CGFloat {
        imageHeight(forWidth: width) + Metrics.homeHeroFadeBand
    }

    var body: some View {
        let height = Self.height(forWidth: width)
        let imageHeight = Self.imageHeight(forWidth: width)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .topTrailing) { artwork(imageHeight: imageHeight) }
            .clipped()
            .overlay { scrims(imageFraction: height > 0 ? imageHeight / height : 1) }
            // 点图本身进详情 —— 这是**唯一**的「进详情」入口(2026-10-15 起没有详情按钮了)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenDetail)
            .overlay(alignment: .bottomLeading) {
                info
                    .padding(.horizontal, Metrics.spacingXL)
                    // 文字落在图片区底部,不进过渡带(那里浅色模式下会变白)
                    .padding(.bottom, Metrics.homeHeroFadeBand + Metrics.spacingS)
                    .environment(\.colorScheme, .dark)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("精选:\(title)")
            // 鼠标那条路是「点画面」,辅助功能看不见画面 —— 动作得单独给
            .accessibilityAction(named: Text("查看详情")) { onOpenDetail() }
    }

    // MARK: - 图层

    private func artwork(imageHeight: CGFloat) -> some View {
        // 清晰图的宽度:完整的 16:9;窗口比它还窄时就是整宽(这时裁两侧,不留空)
        let sharpWidth = min(width, imageHeight * Metrics.homeHeroImageAspect)
        let isInset = sharpWidth < width
        return ZStack(alignment: .topTrailing) {
            // 两层模糊底图都用 `Color.clear.overlay` 包:`.fill` 的图会按**图片自己**的比例上报尺寸,
            // 竖版海报铺满整宽能把 ZStack 撑到 2000+pt 高,清晰图跟着被挤出可见区
            // (2026-10-15 实测 ZStack 高 2592)。`Color.clear` 只吃提议的尺寸,图在 overlay 里溢出再裁掉
            Color.black
                .overlay {
                    if let posterSpec {
                        PosterImage(spec: posterSpec, store: store, showsPlaceholder: false)
                            .blur(radius: Metrics.homeHeroFallbackBlur)
                            .scaleEffect(Metrics.heroBackdropScale)
                    }
                }
                // 同一张图整宽铺满、重度模糊:清晰图左边空出来的地方与过渡带都靠它
                .overlay {
                    PosterImage(spec: backdropSpec, store: store, showsPlaceholder: false)
                        .blur(radius: Metrics.homeHeroAmbientBlur)
                        .scaleEffect(Metrics.heroBackdropScale)
                }
                .clipped()
            PosterImage(spec: backdropSpec, store: store, showsPlaceholder: false) { loaded in
                if !loaded { onBackdropUnavailable() }
            }
            .frame(width: sharpWidth, height: imageHeight)
            .clipped()
            // 左边缘:只有没铺满整宽时才融进模糊底图
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: isInset ? .clear : .black, location: 0),
                        .init(color: .black, location: isInset ? 0.3 : 0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            // 下边缘:融进模糊底图,再由过渡带接到窗口底色
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.65),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .accessibilityHidden(true)
    }

    /// - Parameter imageFraction: 图片区占 hero 总高的比例(过渡带从这里开始)
    private func scrims(imageFraction: Double) -> some View {
        let windowColor = Color(nsColor: .windowBackgroundColor)
        let band = 1 - imageFraction
        return ZStack {
            // 文字区压暗,只在图片区;过渡带里淡掉,否则浅色模式下过渡带左半边是灰的
            LinearGradient(
                colors: [.black.opacity(Metrics.homeHeroSideScrimOpacity), .clear],
                startPoint: .leading,
                endPoint: UnitPoint(x: Metrics.homeHeroSideScrimEnd, y: 0.5)
            )
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: imageFraction - band * 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // 过渡带:缓动(ease-in-out)而不是线性,开头几乎看不出、结尾贴着窗口底色收住
            LinearGradient(
                stops: [
                    .init(color: windowColor.opacity(0), location: imageFraction - band * 0.5),
                    .init(color: windowColor.opacity(0.15), location: imageFraction),
                    .init(color: windowColor.opacity(0.55), location: imageFraction + band * 0.4),
                    .init(color: windowColor.opacity(0.9), location: imageFraction + band * 0.75),
                    .init(color: windowColor, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - 文字与按钮

    private var info: some View {
        HStack(alignment: .bottom, spacing: Metrics.spacingXL) {
            if let coverSpec {
                PosterImage(spec: coverSpec, store: store, showsPlaceholder: false)
                    .frame(width: Metrics.homeHeroPosterWidth, height: Metrics.homeHeroPosterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .shadow(color: .black.opacity(0.5), radius: Metrics.spacingM, y: Metrics.spacingXS)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                titleView
                if let subtitle {
                    Text(subtitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                metaRow
                if let overview {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: Metrics.homeHeroOverviewMaxWidth, alignment: .leading)
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
                // 电影 / 分集 / 剧集都能直接播(剧集由调用方先定位分集);其余类型不给
                if isPlayable {
                    playButton
                        .padding(.top, Metrics.spacingS)
                }
            }
        }
        .frame(maxWidth: Metrics.contentMaxWidth + Metrics.homeHeroPosterWidth, alignment: .leading)
    }

    /// 标题:**Logo 与文字标题同时出现**(Logo 在上、文字在下)。
    ///
    /// ⛔ 不再「有 Logo 就只画 Logo」(2026-10-15 用户反馈):不少 Logo 是花体 / 图形化的
    /// 艺术字,甚至就是个圆形徽章,单看根本认不出片名。文字标题始终在,有 Logo 时字号降一级,
    /// 让 Logo 当装饰、文字负责可读。
    private var titleView: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            if let logoSpec, !isLogoUnavailable {
                PosterImage(spec: logoSpec, store: store, showsPlaceholder: false) { loaded in
                    if !loaded { isLogoUnavailable = true }
                }
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Metrics.homeHeroLogoMaxWidth, maxHeight: Metrics.homeHeroLogoMaxHeight, alignment: .bottomLeading)
                .accessibilityHidden(true)
            }
            Text(title)
                .font(hasLogo ? .title.bold() : .largeTitle.bold())
                .lineLimit(2)
                .shadow(color: .black.opacity(0.4), radius: Metrics.spacingS)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var hasLogo: Bool { logoSpec != nil && !isLogoUnavailable }

    /// 唯一的按钮:「播放 / 继续播放」。调用方用 `if isPlayable` 挡着(见 `info`)。
    ///
    /// **剧集也有**(2026-10-15 用户要求):点了由 `HomeViewModel.playSeries` 定位分集 ——
    /// 看过就接着看(NextUp → 可续播),没看过就第一季第一集,与详情页同一套规则
    /// (`ServerConnection.seriesPlaybackEpisode`)。定位要发请求,所以只在点击时做,
    /// 期间按钮转圈。剧集一律叫「播放」:点之前不知道会落到哪一集、有没有进度,
    /// ⛔ 不为了换文案在渲染时预先去查。
    /// 不带 tint 的透明玻璃(`.glass`,文字区强制深色外观 → 白字)。⛔ 不用 `.glassProminent`
    /// (吃系统强调色,一块饱和蓝压在照片上很突兀),也 ⛔ 不用白底实心胶囊(试过,用户要透明玻璃)。
    ///
    /// ⛔ 不再有「详情 / 查看详情」按钮(2026-10-15 用户要求去掉):hero 整块本来就是可点的
    /// (根视图的 `.contentShape` + `onTapGesture(onOpenDetail)`),再来一个按钮只是把
    /// 一个已经存在的动作画第二遍;而且在剧集上它是**唯一**的按钮、铺成一整条横排,
    /// 压在标题旁边很难看。进详情这条路只保留「点画面」。
    /// 无障碍那边补了同名的 `accessibilityAction`(见 `body`),⛔ 别让辅助功能
    /// 因为少了一个按钮就丢掉这条路径。
    ///
    private var playButton: some View {
        Button(action: onPlay) {
            HStack(spacing: Metrics.spacingS) {
                if isResolvingPlayback {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(item.progressFraction == nil ? "播放" : "继续播放")
            }
            .padding(.horizontal, Metrics.spacingS)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(isResolvingPlayback)
    }

    // MARK: - 数据

    private var isPlayable: Bool { item.kind == .movie || item.kind == .episode || item.kind == .series }

    /// 分集显示剧名(副标题是「S1E3 · 集名」),其余显示自己的名字
    private var title: String {
        item.kind == .episode ? (item.seriesName ?? item.name) : item.name
    }

    private var subtitle: String? {
        guard item.kind == .episode else { return nil }
        return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }

    /// 元信息行:评分(星标)· 年份 · 片长 · 前两个类型。
    ///
    /// 评分放**行首**(2026-10-16 用户要求补上年份与评分):它是标题之下最想做
    /// 决定依据的信息,和年份挨着当一组读。星标样式与详情页 `DetailMetaLine`
    /// 同款(multicolor 黄星),不另造第二种。
    /// 评分和各段都没有时整行不画。
    @ViewBuilder
    private var metaRow: some View {
        let rating = MediaFormat.rating(item.communityRating)
        if rating != nil || meta != nil {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingXS) {
                if let rating {
                    Label(rating, systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .symbolRenderingMode(.multicolor)
                        .accessibilityLabel("评分 \(rating)")
                    if meta != nil {
                        Text("·")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                if let meta {
                    Text(meta)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
        }
    }

    /// 年份 · 片长 · 前两个类型。分集也给(退路单张多半是「继续观看」的分集,
    /// 它同样需要这两行元信息;类型那段在分集上自然为空 —— 列表接口没为它要 `Genres`)
    private var meta: String? {
        let parts = [
            item.productionYear.map(String.init),
            MediaFormat.runtime(ticks: item.runTimeTicks),
            item.genres.flatMap { $0.isEmpty ? nil : $0.prefix(2).joined(separator: " / ") },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 简介。只有随机推荐那批显式要了 `Overview`(`ServerConnection.recommendations`),
    /// 退回「继续观看 / 最新」时没有,这一行就不画
    private var overview: String? {
        guard let text = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
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

    /// 标题左边的竖版小封面。分集不给:分集的 `Primary` 是 16:9 剧照,塞进 2:3 只剩中间一条
    private var coverSpec: ImageSpec? {
        item.kind == .episode ? nil : posterSpec
    }

    /// 分集用剧的 Logo(`logoSource` 自带父级回退)
    private var logoSpec: ImageSpec? {
        item.logoSource.map {
            ImageSpec(serverID: serverID, itemID: $0.itemID, type: .logo, tag: $0.tag,
                      maxWidth: Int(Metrics.homeHeroLogoMaxWidth * 2))
        }
    }
}
