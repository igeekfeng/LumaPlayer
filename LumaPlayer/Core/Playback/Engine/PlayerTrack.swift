import Foundation

/// 一条媒体轨道(**与内核无关**;内核的轨道结构在 `Core/Erika/` 里转换)。
///
/// 只保留 LumaPlayer 真正要用的字段:
/// - `id` 用于选轨(引擎侧按自己的编号体系解释);
/// - `kind` / `source` 用于换算上报的 Emby 流索引(`StreamIndexMapper`);
/// - `selected` 是**读回**结果 —— 设置选轨后要靠它确认是否生效;
/// - `title` / `language` / `codec` 用于菜单显示与中文字幕偏好判定。
///
/// ⛔ 没有「强制(forced)」字段:这是 mpv 专有的容器标记,当前内核(Erika)
/// 的轨道模型里没有,所以 `SubtitleMode.forcedOnly` 一并去掉。
struct PlayerTrack: Sendable, Equatable, Identifiable {
    let id: Int64
    let kind: PlayerTrackKind
    let source: PlayerTrackSource
    let selected: Bool
    let title: String?
    let language: String?
    let codec: String?

    /// 是否外挂轨(Emby 的 `IsExternal` 对应这个)
    var isExternal: Bool { source == .external }

    /// 菜单显示名:title → language →「轨道 N」。
    /// ⛔ 没有 title 也没有 language 时不得显示空串。
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let language, !language.isEmpty { return language }
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

/// 轨道类型。内核若给了别的类型(如附件)归到 `other`,不猜未知值。
enum PlayerTrackKind: String, Sendable, Equatable {
    case video
    case audio
    case subtitle
    case other
}

/// 轨道来源:容器内嵌 / 外挂加载。
enum PlayerTrackSource: String, Sendable, Equatable {
    case embedded
    case external
}
