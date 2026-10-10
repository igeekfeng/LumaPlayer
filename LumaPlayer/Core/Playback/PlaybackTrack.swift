import Foundation

/// 一条可选的音轨 / 字幕轨,交给上面的策略代码使用。
///
/// ## 为什么有这一层
///
/// 在 `main` 上它由 mpv 的 `track-list/N` 节点解析而来(`MPVTrack`)。
/// `exp/avkit-rust-core` 分支把播放内核换成 AVKit 后,同样的信息来自
/// `AVMediaSelectionGroup` —— **字段语义完全一致**,因此依赖它的
/// `StreamIndexMapper` 与 `SubtitlePreference` 不必跟着改,只换生产者。
///
/// 这也是这个类型不放在 `Core/MPV/` 下的原因:它是**播放层的公开形状**,
/// 不是某个内核的私有结构。
///
/// ⛔ 不设 `srcID`:那是容器轨道号(从 1 起),**不是** Emby 的
/// `MediaStream.Index`(从 0 起),曾因直接透传导致轨道上报整体偏一位
/// (docs/PITFALLS.md Q21)。换算一律走 `StreamIndexMapper`。
///
/// ⛔ 不设 `isDefault`:内核的「默认轨」标记与 Emby 的 `IsDefault` 不是一回事,
/// 至今没有用到它的地方,不先解出来占着。
struct PlaybackTrack: Sendable, Equatable, Identifiable {
    /// 内核内部的轨道号(选轨时回传给内核)
    let id: Int
    let type: PlaybackTrackType
    let selected: Bool
    let title: String?
    let lang: String?
    let codec: String?
    /// 外挂轨(不在容器里,另行加载)
    let isExternal: Bool
    /// 容器里标了「强制」的字幕
    let isForced: Bool

    /// 菜单显示名:title → lang →「轨道 N」。⛔ 两个都空时不得显示空串。
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let lang, !lang.isEmpty { return lang }
        return "轨道 \(id)"
    }

    /// 菜单副标题(编码 + 外挂标记);都没有时返回 nil,不显示空括号。
    var detail: String? {
        var parts: [String] = []
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if isExternal { parts.append("外挂") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 轨道类型。
///
/// 三类是内核与 Emby 都能表达的最小公共集;其余(如附件轨)归到 `other`,
/// ⛔ 不猜未知值 —— 猜错会把一条附件轨当字幕报上去。
enum PlaybackTrackType: String, Sendable, Equatable {
    case video
    case audio
    case sub
    case other
}
