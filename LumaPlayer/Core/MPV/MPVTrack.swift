import Foundation
import mpv

/// 一条 mpv 轨道(`track-list/N`,MPV_INTEGRATION.md 第 7 节),只解用得到的字段。
///
/// ⛔ 不解 `src-id`:容器轨道号从 1 起,不是 Emby `MediaStream.Index`(Q21)。
/// 不解 `default`:与 Emby `IsDefault` 不是一回事,也没人用。
struct MPVTrack: Sendable, Equatable, Identifiable {
    /// `aid` / `sid` 设的就是它
    let id: Int
    let type: MPVTrackType
    let selected: Bool
    let title: String?
    let lang: String?
    let codec: String?
    let isExternal: Bool
    /// `track-list/N/forced`
    let isForced: Bool
    /// 封面图伪装的视频轨(`albumart`),不算真画面
    var isAlbumArt = false
    /// `track-list/N/dolby-vision-profile`(demuxer 读出);非 DV 片源为 nil
    var dolbyVisionProfile: Int? = nil

    /// title → lang →「轨道 N」,⛔ 不显示空串。
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let lang, !lang.isEmpty { return lang }
        return "轨道 \(id)"
    }

    /// 编码 + 外挂标记;都没有时 nil。
    var detail: String? {
        var parts: [String] = []
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if isExternal { parts.append("外挂") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// mpv 只保证 `video`/`audio`/`sub`(input.rst:3555),其余归 `other`。
enum MPVTrackType: String, Sendable, Equatable {
    case video
    case audio
    case sub
    case other
}

// MARK: - track-list 节点解析

/// `track-list` 的 `mpv_node` 解析。C API 边界,只在 `Core/MPV/` 内调用;结果全是值类型。
///
/// 事件里的节点归 mpv 所有,下一次 `mpv_wait_event()` 自动释放(client.h:1712-1714)。
/// ⛔ 不得再调 `mpv_free_node_contents`(会触发 talloc 断言、SIGABRT);必须同步解析完,不持有指针。
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
            isExternal: flag("external"),
            isForced: flag("forced"),
            isAlbumArt: flag("albumart"),
            dolbyVisionProfile: integer("dolby-vision-profile")
        )
    }
}
