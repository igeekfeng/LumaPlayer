import Foundation
import mpv

/// 一条 mpv 轨道(`track-list/N` 的一个元素,MPV_INTEGRATION.md 第 7 节)。
///
/// 只解 LumaPlayer 真正要用的字段:`id` 用于 `aid`/`sid` 设值,
/// `type` / `isExternal` 用于换算上报的 Emby 流索引(`StreamIndexMapper`),
/// 其余用于菜单显示。
///
/// ⛔ 不解 `src-id`:它是容器轨道号(从 1 起),**不是** Emby 的
/// `MediaStream.Index`(从 0 起),曾因直接透传导致轨道上报整体偏一位
/// (docs/PITFALLS.md Q21)。
struct MPVTrack: Sendable, Equatable, Identifiable {
    /// mpv 的轨道号;`aid` / `sid` 设的就是它
    let id: Int
    let type: MPVTrackType
    let selected: Bool
    let title: String?
    let lang: String?
    let codec: String?
    let isExternal: Bool

    /// 菜单显示名:title → lang →「轨道 N」(MPV_INTEGRATION.md 第 7 节的优先级)。
    /// ⛔ 没有 title 也没有 lang 时不得显示空串。
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

/// `track-list/N/type` 的取值。mpv 只保证 `video`/`audio`/`sub` 三种
/// (input.rst:3555),其余(如 attachment)归到 `other`,不猜未知值。
enum MPVTrackType: String, Sendable, Equatable {
    case video
    case audio
    case sub
    case other
}

// MARK: - track-list 节点解析

/// `track-list` 的 `mpv_node` 解析。
///
/// ⛔ 这是 C API 边界,只允许在 `Core/MPV/` 内调用(并发论证见
/// `MPVPlayer` 类注释)。解析结果全是值类型 → Sendable,可以安全地
/// 经 `MPVEventBridge` 送到 MainActor。
///
/// ## 内存归属(易错点)
/// 事件里的节点**归 mpv 所有**,client.h:1712-1714:下一次 `mpv_wait_event()`
/// 会自动释放它 —— 调用方 ⛔ **不得**再调 `mpv_free_node_contents`
/// (实测:多调一次会在 mpv 内部的 `copy_node`/`free_node` 触发 talloc 断言,
/// 进程 SIGABRT)。解析因此必须同步完成,本文件不持有任何指针。
enum MPVTrackListParser {
    static func parse(_ node: inout mpv_node) -> [MPVTrack] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { return [] }
        let count = Int(list.pointee.num)
        guard let values = list.pointee.values else { return [] }
        var tracks: [MPVTrack] = []
        tracks.reserveCapacity(count)
        for index in 0..<count {
            let entry = values[index]
            guard entry.format == MPV_FORMAT_NODE_MAP, let map = entry.u.list else { continue }
            tracks.append(track(from: map))
        }
        return tracks
    }

    private static func track(from map: UnsafePointer<mpv_node_list>) -> MPVTrack {
        let count = Int(map.pointee.num)
        let keys = map.pointee.keys
        let values = map.pointee.values

        func string(_ name: String) -> String? {
            for index in 0..<count {
                guard let key = keys?[index], String(cString: key) == name else { continue }
                let value = values?[index]
                guard value?.format == MPV_FORMAT_STRING, let raw = value?.u.string else { return nil }
                return String(cString: raw)
            }
            return nil
        }

        func integer(_ name: String) -> Int? {
            for index in 0..<count {
                guard let key = keys?[index], String(cString: key) == name else { continue }
                let value = values?[index]
                switch value?.format {
                case MPV_FORMAT_INT64: return Int((value?.u.int64) ?? 0)
                // 字段名是 `double_`(client.h:769),`double` 在 C 里是关键字
                case MPV_FORMAT_DOUBLE: return Int((value?.u.double_) ?? 0)
                default: return nil
                }
            }
            return nil
        }

        func flag(_ name: String) -> Bool {
            for index in 0..<count {
                guard let key = keys?[index], String(cString: key) == name else { continue }
                let value = values?[index]
                return (value?.u.flag ?? 0) != 0
            }
            return false
        }

        let rawType = string("type")
        return MPVTrack(
            id: integer("id") ?? 0,
            type: MPVTrackType(rawValue: rawType ?? "") ?? .other,
            selected: flag("selected"),
            title: string("title"),
            lang: string("lang"),
            codec: string("codec"),
            isExternal: flag("external")
        )
    }
}
