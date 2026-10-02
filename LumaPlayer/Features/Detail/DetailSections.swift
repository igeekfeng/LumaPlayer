import SwiftUI
import AppKit

// 详情页的各个区块。拆成独立视图:详情页 body 不至于大到
// 类型检查器吃不消,且每块只读自己用到的字段。

// MARK: - Hero

/// 背景图 hero:整幅剧照 + 底部渐变到窗口背景,海报与标题区压在渐变上。
///
/// 背景图用 `backgroundExtensionEffect()` 延伸到工具栏下面
/// (macOS 27 Liquid Glass 的原生做法,内容本身不被拉伸)。
/// 没有背景图时 hero 变矮,只留一层很淡的渐变 —— 不拿占位图撑出一大块灰。
struct DetailHero<Header: View>: View {
    let detail: EmbyItem
    let server: ServerProfile
    let store: PosterImageStore
    @ViewBuilder var header: () -> Header

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backdrop
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.35),
                            .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            HStack(alignment: .bottom, spacing: Metrics.spacingXL) {
                poster
                header()
            }
            .padding(.horizontal, Metrics.spacingXL)
            .padding(.top, -heroHeight * Self.overlapRatio)
        }
    }

    /// 标题区向上压进 hero 的比例:压太多标题会落在图最亮的地方,太少则显得脱节
    private static var overlapRatio: CGFloat { 0.45 }

    private var heroHeight: CGFloat {
        let full = Metrics.contentMaxWidth * 9 / 16
        return detail.backdropSource == nil ? full / 2 : full
    }

    @ViewBuilder
    private var backdrop: some View {
        if let source = detail.backdropSource {
            PosterImage(
                spec: ImageSpec(
                    serverID: server.id,
                    itemID: source.itemID,
                    type: .backdrop,
                    tag: source.tag,
                    maxWidth: Int(Metrics.contentMaxWidth * 2)
                ),
                store: store,
                placeholderSystemImage: "photo"
            )
            .backgroundExtensionEffect()
            .accessibilityHidden(true)
        } else {
            LinearGradient(
                colors: [Color.secondary.opacity(0.18), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// 分集的 Primary 是 16:9 剧照,其余是 2:3 海报 —— 按实际比例放,不裁成海报。
    @ViewBuilder
    private var poster: some View {
        let isLandscape = detail.kind == .episode
        let width = isLandscape ? Metrics.posterMinWidth * 1.6 : Metrics.posterMinWidth
        PosterImage(
            spec: detail.primaryImageTagValue.map {
                ImageSpec(
                    serverID: server.id,
                    itemID: detail.id,
                    type: .primary,
                    tag: $0,
                    maxWidth: Int(width * 2)
                )
            },
            store: store,
            placeholderSystemImage: isLandscape ? "tv" : "film"
        )
        .aspectRatio(isLandscape ? 16.0 / 9.0 : Metrics.posterAspectRatio, contentMode: .fit)
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(0.3), radius: Metrics.spacingM, y: Metrics.spacingXS)
        .accessibilityHidden(true)
    }
}

// MARK: - 标题

/// 有 Logo 图就用 Logo(Infuse / Apple TV 的做法),没有就用文字标题。
/// Logo 加载失败时 `PosterImage` 会停在占位图 —— 所以这里只在确有 tag 时才走图片,
/// 且始终保留文字标题给 VoiceOver。
struct DetailTitle: View {
    let detail: EmbyItem
    let server: ServerProfile
    let store: PosterImageStore

    private static var logoMaxWidth: CGFloat { Metrics.contentMaxWidth / 2 }

    var body: some View {
        if let logo = detail.logoSource, detail.kind != .episode {
            PosterImage(
                spec: ImageSpec(
                    serverID: server.id,
                    itemID: logo.itemID,
                    type: .logo,
                    tag: logo.tag,
                    maxWidth: Int(Self.logoMaxWidth * 2)
                ),
                store: store,
                placeholderSystemImage: "textformat"
            )
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: Self.logoMaxWidth, maxHeight: Metrics.posterMinWidth / 2, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel(detail.name)
            .accessibilityAddTraits(.isHeader)
        } else {
            Text(detail.name)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: - 元信息行

/// 「2024 · 1 小时 42 分钟 · ★ 8.1 · [PG-13] · 21:35 结束」。缺哪个字段就不显示哪一段。
struct DetailMetaLine: View {
    let detail: EmbyItem

    var body: some View {
        HStack(spacing: Metrics.spacingS) {
            ForEach(Array(textParts.enumerated()), id: \.offset) { index, part in
                if index > 0 { separator }
                Text(part)
            }
            if let rating = MediaFormat.rating(detail.communityRating) {
                if !textParts.isEmpty { separator }
                Label(rating, systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.multicolor)
                    .accessibilityLabel("评分 \(rating)")
            }
            if let official = detail.officialRating, !official.isEmpty {
                Text(official)
                    .font(.caption)
                    .padding(.horizontal, Metrics.spacingXS)
                    .overlay(RoundedRectangle(cornerRadius: Metrics.spacingXS).stroke(.secondary))
                    .accessibilityLabel("分级 \(official)")
            }
            if let endsAt = MediaFormat.endsAt(for: detail), detail.kind != .series {
                separator
                Text("\(endsAt.formatted(date: .omitted, time: .shortened)) 结束")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var separator: some View {
        Text("·").accessibilityHidden(true)
    }

    private var textParts: [String] {
        var parts: [String] = []
        if detail.kind == .episode {
            if let label = detail.episodeLabel { parts.append(label) }
            if let date = MediaFormat.date(detail.premiereDate) { parts.append(date) }
        } else if let year = detail.productionYear {
            parts.append(String(year))
        }
        if detail.kind == .series, let seasons = detail.childCount, seasons > 0 {
            parts.append("共 \(seasons) 季")
        }
        if detail.kind != .series, let runtime = MediaFormat.runtime(ticks: detail.runTimeTicks) {
            parts.append(runtime)
        }
        return parts
    }
}

// MARK: - 媒体信息

/// 视频 / 音频 / 字幕概况。文案直接用服务端的 `DisplayTitle`(如 `720p H264`),
/// 不在客户端拼编码名 —— 服务端已经本地化并处理过各种边角情况。
struct DetailMediaInfo: View {
    let streams: [EmbyMediaStream]

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("媒体信息")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: Metrics.spacingL,
                     verticalSpacing: Metrics.spacingXS) {
                    ForEach(rows, id: \.label) { row in
                        GridRow {
                            Label(row.label, systemImage: row.symbol)
                                .foregroundStyle(.secondary)
                            Text(row.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private struct Row {
        let label: String
        let symbol: String
        let value: String
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let video = summary(of: "Video") {
            rows.append(Row(label: "视频", symbol: "film", value: video))
        }
        if let audio = summary(of: "Audio") {
            rows.append(Row(label: "音频", symbol: "waveform", value: audio))
        }
        if let subtitle = summary(of: "Subtitle") {
            rows.append(Row(label: "字幕", symbol: "captions.bubble", value: subtitle))
        }
        return rows
    }

    /// 同类轨道最多列 3 条,其余合成「等 N 条」。
    private func summary(of type: String) -> String? {
        let titles = streams
            .filter { $0.type == type }
            .compactMap { $0.displayTitle ?? $0.title ?? $0.codec?.uppercased() }
        guard !titles.isEmpty else { return nil }
        let shown = titles.prefix(Self.maxListed).joined(separator: "、")
        return titles.count > Self.maxListed ? "\(shown) 等 \(titles.count) 条" : shown
    }

    private static let maxListed = 3
}

// MARK: - 演职人员

struct DetailPeopleRow: View {
    let people: [EmbyPerson]
    let server: ServerProfile
    let store: PosterImageStore

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("演职人员")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Metrics.spacingL) {
                        ForEach(people.prefix(Self.maxShown)) { person in
                            personCard(person)
                        }
                    }
                    .padding(.vertical, Metrics.spacingXS)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private static let maxShown = 30
    private static let avatarSize = Metrics.posterMinWidth / 2

    private func personCard(_ person: EmbyPerson) -> some View {
        VStack(spacing: Metrics.spacingXS) {
            PosterImage(
                spec: person.primaryImageTag.map {
                    ImageSpec(
                        serverID: server.id,
                        itemID: person.id,
                        type: .primary,
                        tag: $0,
                        maxWidth: Int(Self.avatarSize * 2)
                    )
                },
                store: store,
                placeholderSystemImage: "person.fill"
            )
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())
            Text(person.name)
                .font(.caption)
                .lineLimit(1)
            if let role = person.role ?? person.type, !role.isEmpty {
                Text(role)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.avatarSize * 1.3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 其他信息

/// 导演 / 编剧 / 制片公司 / 首映。都没有就整块不显示。
struct DetailFacts: View {
    let detail: EmbyItem

    var body: some View {
        let facts = self.facts
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text("信息")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: Metrics.spacingL,
                     verticalSpacing: Metrics.spacingXS) {
                    ForEach(facts, id: \.0) { label, value in
                        GridRow {
                            Text(label).foregroundStyle(.secondary)
                            Text(value).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var facts: [(String, String)] {
        var facts: [(String, String)] = []
        let people = detail.people ?? []
        let directors = people.filter { $0.type == "Director" }.map(\.name)
        if !directors.isEmpty { facts.append(("导演", directors.joined(separator: "、"))) }
        let writers = people.filter { $0.type == "Writer" }.map(\.name)
        if !writers.isEmpty { facts.append(("编剧", writers.joined(separator: "、"))) }
        let studios = (detail.studios ?? []).map(\.name).filter { !$0.isEmpty }
        if !studios.isEmpty { facts.append(("制片公司", studios.joined(separator: "、"))) }
        if detail.kind != .episode, let date = MediaFormat.date(detail.premiereDate) {
            facts.append((detail.kind == .series ? "首播" : "首映", date))
        }
        return facts
    }
}
