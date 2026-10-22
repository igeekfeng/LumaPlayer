import Foundation

/// mpv 轨道 → Emby `MediaStream.Index`(上报 `AudioStreamIndex` / `SubtitleStreamIndex`,Q21)。
///
/// ⛔ 不用 mpv 的 `src-id`(从 1 起,透传会整体偏一位)或 `ff-index`(mpv 对非 lavf demuxer 不保证)。
/// 规则:同类型内嵌轨按顺序一一对应(第 k 条 mpv 音轨 ↔ 按 `Index` 排序后第 k 条 Emby `Audio` 流)。
///
/// 返回 nil(上报时整键省略,不报胜过报错位的值):转码流(轨道构成由服务端决定)、外挂轨、
/// 同类型内嵌轨条数不一致或 Emby 流缺 `Index`。
enum StreamIndexMapper {
    static func embyIndex(
        for trackID: Int,
        tracks: [MPVTrack],
        streams: [EmbyMediaStream]?,
        method: PlaybackMethod
    ) -> Int? {
        guard method == .directStream else { return nil }
        guard let track = tracks.first(where: { $0.id == trackID }), !track.isExternal else { return nil }
        guard let embyType = embyType(for: track.type), let streams else { return nil }

        let mpvSameType = tracks
            .filter { $0.type == track.type && !$0.isExternal }
            .sorted { $0.id < $1.id }
        let embySameType = streams.filter { $0.type == embyType && $0.isExternal != true }
        let embyIndices = embySameType.compactMap(\.index).sorted()

        guard embyIndices.count == embySameType.count,
              embyIndices.count == mpvSameType.count,
              let position = mpvSameType.firstIndex(where: { $0.id == trackID })
        else { return nil }
        return embyIndices[position]
    }

    /// Emby `MediaStream.Type` 取值(API_CONTRACT.md 4.3)
    private static func embyType(for type: MPVTrackType) -> String? {
        switch type {
        case .audio: return "Audio"
        case .sub: return "Subtitle"
        case .video, .other: return nil
        }
    }
}
