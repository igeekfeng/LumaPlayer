import XCTest
@testable import LumaPlayer

/// mpv 轨道 → Emby `MediaStream.Index` 的换算(docs/PITFALLS.md Q21)。
///
/// 用例数据取自本地 Emby 4.9.5.0 实例上 `02-multi-track.mkv` 的实测:
/// mpv 的 `src-id` 从 1 起,Emby 的 `Index` 从 0 起,早先直接透传 `src-id`
/// 导致上报整体偏一位。这里断言的是**换算后的 Emby 索引**,不是 mpv 编号。
final class StreamIndexMapperTests: XCTestCase {

    /// mpv 的轨道号按类型各自从 1 编号
    private static let tracks: [MPVTrack] = [
        track(1, .video),
        track(1, .audio, lang: "eng"),
        track(2, .audio, lang: "chi"),
        track(1, .sub, lang: "eng"),
        track(2, .sub, lang: "chi"),
    ]

    private static let streams: [EmbyMediaStream] = [
        stream(0, "Video"),
        stream(1, "Audio"),
        stream(2, "Audio"),
        stream(3, "Subtitle"),
        stream(4, "Subtitle"),
    ]

    // MARK: - 对应规则

    /// 实测场景:mpv 播 English(aid=1)时,服务端必须收到 1(不是 src-id 的 2)。
    func testAudioTracksMapByOrderWithinType() {
        XCTAssertEqual(map(1, .audio), 1)
        XCTAssertEqual(map(2, .audio), 2)
    }

    /// 字幕同理:切到 Chinese(sid=2)对应 Emby 的 4,而不是某条音轨或越界
    func testSubtitleTracksMapByOrderWithinType() {
        XCTAssertEqual(map(1, .sub), 3)
        XCTAssertEqual(map(2, .sub), 4)
    }

    /// Emby 的 `Index` 不连续(中间夹着别的类型、或服务端给的顺序打乱)时,
    /// 仍按同类型内的 Index 升序对应。
    func testNonContiguousAndUnsortedEmbyIndices() {
        let streams = [
            Self.stream(5, "Audio"),
            Self.stream(0, "Video"),
            Self.stream(2, "Audio"),
            Self.stream(3, "Subtitle"),
        ]
        XCTAssertEqual(map(1, .audio, streams: streams), 2)
        XCTAssertEqual(map(2, .audio, streams: streams), 5)
    }

    // MARK: - 对不齐一律 nil(整键省略,不上报错位的值)

    /// 转码流的轨道构成由服务端决定,与源文件的 MediaStreams 不对应
    func testTranscodeNeverMaps() {
        XCTAssertNil(map(1, .audio, method: .transcode))
        XCTAssertNil(map(1, .sub, method: .transcode))
    }

    /// 条数不一致:无从判断哪条对哪条
    func testCountMismatchReturnsNil() {
        let streams = [Self.stream(0, "Video"), Self.stream(1, "Audio")]
        XCTAssertNil(map(1, .audio, streams: streams))
    }

    /// mpv 侧的外挂轨不参与对应;它也不能挤占内嵌轨的序号
    func testExternalMPVTrackIsExcluded() {
        let tracks = Self.tracks + [Self.track(3, .sub, lang: "zh", external: true)]
        XCTAssertNil(map(3, .sub, tracks: tracks))
        XCTAssertEqual(map(2, .sub, tracks: tracks), 4)
    }

    /// Emby 侧的外挂字幕(`IsExternal`)同样不计入内嵌序列
    func testExternalEmbyStreamIsExcluded() {
        let streams = Self.streams + [Self.stream(5, "Subtitle", external: true)]
        XCTAssertEqual(map(2, .sub, streams: streams), 4)
    }

    /// `MediaStreams` 缺失、或有流缺 `Index`:不猜
    func testMissingStreamsOrIndexReturnsNil() {
        XCTAssertNil(StreamIndexMapper.embyIndex(
            for: 1, tracks: Self.tracks.filter { $0.type == .audio },
            streams: nil, method: .directStream))

        let streams = [Self.stream(1, "Audio"), EmbyMediaStream(
            index: nil, type: "Audio", codec: nil, language: nil,
            isDefault: nil, isTextSubtitleStream: nil, isExternal: nil,
            displayTitle: nil, title: nil, width: nil, height: nil, channels: nil)]
        XCTAssertNil(map(1, .audio, streams: streams))
    }

    /// 视频轨不上报,也就不换算
    func testVideoTrackReturnsNil() {
        XCTAssertNil(map(1, .video))
    }

    /// 不存在的轨道号
    func testUnknownTrackIDReturnsNil() {
        XCTAssertNil(map(9, .audio))
    }

    // MARK: - 辅助

    /// 与 `PlayerViewModel` 一致:只把同类型的 mpv 轨道传进来
    private func map(
        _ id: Int,
        _ type: MPVTrackType,
        tracks: [MPVTrack] = StreamIndexMapperTests.tracks,
        streams: [EmbyMediaStream] = StreamIndexMapperTests.streams,
        method: PlaybackMethod = .directStream
    ) -> Int? {
        StreamIndexMapper.embyIndex(
            for: id,
            tracks: tracks.filter { $0.type == type },
            streams: streams,
            method: method
        )
    }

    private static func track(
        _ id: Int, _ type: MPVTrackType, lang: String? = nil, external: Bool = false
    ) -> MPVTrack {
        MPVTrack(id: id, type: type, selected: false, title: nil, lang: lang,
                 codec: nil, isExternal: external, isForced: false)
    }

    private static func stream(_ index: Int, _ type: String, external: Bool = false) -> EmbyMediaStream {
        EmbyMediaStream(index: index, type: type, codec: nil, language: nil,
                        isDefault: nil, isTextSubtitleStream: nil, isExternal: external,
                        displayTitle: nil, title: nil, width: nil, height: nil, channels: nil)
    }
}
