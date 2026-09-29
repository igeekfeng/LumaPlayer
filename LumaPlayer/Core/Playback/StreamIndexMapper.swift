import Foundation

/// mpv 轨道 → Emby `MediaStream.Index` 的对应(上报 `AudioStreamIndex` /
/// `SubtitleStreamIndex` 用,docs/PITFALLS.md Q21)。
///
/// ## 为什么不用 mpv 的 `src-id` / `ff-index`
///
/// - `src-id` 是容器内轨道号(mkv/mp4 从 1 起),Emby 的 `Index` 从 0 起 ——
///   直接透传会整体偏一位(本地 Emby 4.9.5.0 实测:播 English 音轨时上报成
///   Chinese,切到 Chinese 后上报成一条字幕流的索引)。
/// - `ff-index` 实测与 Emby 一致,但 mpv 文档对非 lavf demuxer 明说
///   「no hard guarantee」,不拿一个没承诺的字段当契约。
///
/// ## 对应规则
///
/// 同一类型的**内嵌**轨按出现顺序一一对应:第 k 条 mpv 音轨 ↔ 按 `Index`
/// 排序后的第 k 条 Emby `Audio` 流(字幕同理)。两边描述的是同一个文件、
/// 同一个容器顺序,这是不依赖任何编号约定的最弱假设。
///
/// 以下情况一律返回 nil(上报时整键省略 —— 不上报胜过上报一个错位的值):
/// - 转码流:输出流的轨道构成由服务端决定(可能只含选中的一条音轨、字幕被烧录),
///   与源文件的 `MediaStreams` 不再对应;
/// - 外挂轨(mpv 的 `external` / Emby 的 `IsExternal`):两边不在同一个序列里;
/// - 两边同类型内嵌轨条数不一致,或 Emby 有流缺 `Index`:对不齐就不猜。
///
/// 纯函数,无状态,可脱离网络与 mpv 测试。
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

    /// mpv 轨道类型 → Emby `MediaStream.Type` 的取值(API_CONTRACT.md 4.3)。
    private static func embyType(for type: MPVTrackType) -> String? {
        switch type {
        case .audio: return "Audio"
        case .sub: return "Subtitle"
        case .video, .other: return nil
        }
    }
}
