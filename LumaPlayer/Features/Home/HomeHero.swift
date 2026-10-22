import SwiftUI

/// 首页顶部的 hero:一项内容的整宽背景图 + 标题 + 播放按钮;「进详情」靠点整块画面。
/// 只负责渲染一项,轮播在 `HomeHeroCarousel`;选哪几项见 `HomeViewModel.heroPick`,
/// ⛔ 不为 hero 另发列表请求。
///
/// 布局:图片区(`imageHeight(forWidth:)`)+ 过渡带(`homeHeroFadeBand`)= `height(forWidth:)`。
///
/// 图层自下而上:
/// 1. 模糊海报(`homeHeroFallbackBlur`):背景图 404 时的色调退路(见 `EmbyItem.coverImageFallback`);
/// 2. 同一张背景图重度模糊铺满(`homeHeroAmbientBlur`,含过渡带),同一 spec 命中缓存。
///    ⚠️ 模糊必须重,轻了看得出是同一批人物;镜像接边、拉伸边缘都试过,不如重度模糊;
/// 3. 清晰背景图按图片区高度完整靠右摆放(16:9,窗口更窄才裁两侧),左 / 下边缘渐变融进第 2 层。
///    ⛔ 不铺满整宽(会放大 + 裁上下,见 `homeHeroImageAspect`);取不到就透明,⛔ 不画灰色占位;
/// 4. 左侧压暗(只在图片区)+ 过渡带缓动渐变到窗口底色。⛔ 不在底边硬切,⛔ 不线性淡成白雾。
///
/// 文字固定深色外观(永远压在压暗过的图上)。⛔ 不从图里取色做 tint(DesignTokens.swift「界面规则」)。
struct HomeHero: View {
    let item: EmbyItem
    let serverID: UUID
    let store: PosterImageStore
    let onPlay: () -> Void
    /// 剧集正在定位分集:按钮转圈、不可点
    var isResolvingPlayback = false
    let onOpenDetail: () -> Void
    /// 轮播据此跳过这一项
    var onBackdropUnavailable: () -> Void = {}

    @State private var width: CGFloat = 0
    /// Logo 取不到(或没有)时用文字标题
    @State private var isLogoUnavailable = false

    /// 按宽度算,夹在上下限之间
    static func imageHeight(forWidth width: CGFloat) -> CGFloat {
        min(max(width * Metrics.homeHeroHeightRatio, Metrics.homeHeroMinHeight), Metrics.homeHeroMaxHeight)
    }

    /// 只跟宽度有关,换图不改布局(轮播不跳的前提)
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
            // 唯一的「进详情」入口
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
            // 辅助功能点不到画面,动作单独给
            .accessibilityAction(named: Text("查看详情")) { onOpenDetail() }
    }

    // MARK: - 图层

    private func artwork(imageHeight: CGFloat) -> some View {
        // 完整 16:9;窗口更窄时就是整宽(裁两侧)
        let sharpWidth = min(width, imageHeight * Metrics.homeHeroImageAspect)
        let isInset = sharpWidth < width
        return ZStack(alignment: .topTrailing) {
            // 模糊底图必须放在 overlay 里:`.fill` 的图按自身比例上报尺寸,竖版海报会把 ZStack
            // 撑到 2000+pt 高、清晰图被挤出可见区。底色视图只吃提议尺寸,图在 overlay 里溢出再裁掉
            Color.black
                .overlay {
                    if let posterSpec {
                        PosterImage(spec: posterSpec, store: store, showsPlaceholder: false)
                            .blur(radius: Metrics.homeHeroFallbackBlur)
                            .scaleEffect(Metrics.heroBackdropScale)
                    }
                }
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
            // 左边缘:只有没铺满整宽时才渐隐
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

    /// - Parameter imageFraction: 图片区占总高的比例(过渡带从这里开始)
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
            // 过渡带:缓动而不是线性
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
                if isPlayable {
                    playButton
                        .padding(.top, Metrics.spacingS)
                }
            }
        }
        .frame(maxWidth: Metrics.contentMaxWidth + Metrics.homeHeroPosterWidth, alignment: .leading)
    }

    /// Logo 在上、文字标题在下,同时出现。⛔ 不要「有 Logo 就只画 Logo」:不少 Logo 是艺术字 / 徽章,
    /// 单看认不出片名。有 Logo 时文字降一级字号。
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

    /// 唯一的按钮。剧集也有:点击时才由 `HomeViewModel.playSeries` 定位分集(期间转圈);
    /// 剧集一律叫「播放」,⛔ 不为换文案在渲染时预先去查。
    ///
    /// 透明玻璃 `.glass`。⛔ 不用 `.glassProminent`(饱和强调色压在照片上突兀),⛔ 不用白底实心胶囊。
    /// ⛔ 不加「详情」按钮:整块画面已可点(无障碍走 `accessibilityAction`)。
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

    /// 分集显示剧名(副标题是「S1E3 · 集名」)
    private var title: String {
        item.kind == .episode ? (item.seriesName ?? item.name) : item.name
    }

    private var subtitle: String? {
        guard item.kind == .episode else { return nil }
        return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }

    /// 评分(星标)· 年份 · 片长 · 前两个类型。星标与详情页 `DetailMetaLine` 同款,不另造。
    /// 都没有时整行不画。
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

    /// 分集上类型那段自然为空(列表接口没要 `Genres`)
    private var meta: String? {
        let parts = [
            item.productionYear.map(String.init),
            MediaFormat.runtime(ticks: item.runTimeTicks),
            item.genres.flatMap { $0.isEmpty ? nil : $0.prefix(2).joined(separator: " / ") },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 只有推荐那批要了 `Overview`,退路条目没有就不画
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

    /// 档位与 `MediaCard` 一致,通常命中图片缓存
    private var posterSpec: ImageSpec? {
        item.primaryImageTagValue.map {
            ImageSpec(serverID: serverID, itemID: item.id, type: .primary, tag: $0,
                      maxWidth: Int(Metrics.posterMinWidth * 2))
        }
    }

    /// 分集不给:分集的 `Primary` 是 16:9 剧照,塞进 2:3 只剩中间一条
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
