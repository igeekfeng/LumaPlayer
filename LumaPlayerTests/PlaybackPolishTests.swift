import XCTest
@testable import LumaPlayer

/// 播放打磨里**与播放内核无关**的那部分:章节解码、片头 / 片尾标记、
/// 续播回退规则、统计信息格式化、上一集查找、倍速记忆的作用域。
///
/// ⚠️ `exp/avkit-rust-core` 摘掉 libmpv 后本文件做过一次收缩:凡是要建
/// `PlayerViewModel` 实例(即需要播放内核)的用例都随 ViewModel 一起删了
/// —— 触控板横滑预览、偏好开关联动、起播倍速、缓冲 / 统计开关、跨集的倍速记忆。
/// 那些是**接线**行为,接 AVKit 时在播放层那边重新覆盖;留下来的都是原注释里
/// 就写明「只验不需要 mpv、不需要网络的部分」的规则本身。
///
/// ⛔ 按钮位置、倒计时的实际观感、触控板手感、置顶窗口是 UI 行为,
/// 本机无屏幕录制权限,不在这里假装覆盖。
final class PlaybackPolishTests: XCTestCase {

    // MARK: - 章节解码

    func testChaptersDecodeFromMediaSource() throws {
        let response = try JSONDecoder().decode(
            EmbyPlaybackInfoResponse.self,
            from: try FixtureLoader.data("playback_chapter_markers_synthetic.json"))
        let chapters = try XCTUnwrap(response.mediaSources?.first?.chapters)
        XCTAssertEqual(chapters.count, 5)
        XCTAssertEqual(chapters[1].markerType, "IntroStart")
        XCTAssertEqual(chapters[1].startPositionTicks, 300_000_000)
        // 枚举外的值照样解出来(只是不认识),不能让整个 PlaybackInfo 解码失败
        XCTAssertEqual(chapters[4].markerType, "SomeFutureMarker")
    }

    /// 官方 OpenAPI 4.1.1.0 的 ChapterInfo 没有 `MarkerType`:旧服务器的章节照样能解。
    func testChapterWithoutMarkerTypeStillDecodes() throws {
        let json = #"{"Id":"MS","Chapters":[{"StartPositionTicks":0,"Name":"开头"}]}"#
        let source = try JSONDecoder().decode(EmbyMediaSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.chapters?.first?.name, "开头")
        XCTAssertNil(source.chapters?.first?.markerType)
        XCTAssertEqual(PlaybackMarkers(chapters: source.chapters), .none)
    }

    func testMissingChaptersIsNil() throws {
        let source = try JSONDecoder().decode(EmbyMediaSource.self, from: Data(#"{"Id":"MS"}"#.utf8))
        XCTAssertNil(source.chapters)
    }

    // MARK: - 片头 / 片尾标记

    func testMarkersFromFixture() throws {
        let response = try JSONDecoder().decode(
            EmbyPlaybackInfoResponse.self,
            from: try FixtureLoader.data("playback_chapter_markers_synthetic.json"))
        let markers = PlaybackMarkers(chapters: response.mediaSources?.first?.chapters)
        XCTAssertEqual(markers.intro, 30..<120)
        XCTAssertEqual(markers.creditsStart, 1320)
    }

    func testIntroNeedsBothEndsInOrder() {
        XCTAssertNil(PlaybackMarkers(chapters: [chapter(30, "IntroStart")]).intro, "只有起点")
        XCTAssertNil(PlaybackMarkers(chapters: [chapter(90, "IntroEnd")]).intro, "只有终点")
        XCTAssertNil(
            PlaybackMarkers(chapters: [chapter(90, "IntroStart"), chapter(30, "IntroEnd")]).intro,
            "终点早于起点是脏数据,不显示按钮")
        XCTAssertEqual(
            PlaybackMarkers(chapters: [chapter(0, "IntroStart"), chapter(85, "IntroEnd")]).intro,
            0..<85, "片头从 0 开始是常见情况")
    }

    func testIsInIntroHonoursTailTolerance() {
        let markers = PlaybackMarkers(intro: 30..<120, creditsStart: nil)
        XCTAssertFalse(markers.isInIntro(29.9, tailTolerance: 1))
        XCTAssertTrue(markers.isInIntro(30, tailTolerance: 1))
        XCTAssertTrue(markers.isInIntro(118.9, tailTolerance: 1))
        // 最后 1 秒不再显示:跳过省不了什么,还会在终点附近闪
        XCTAssertFalse(markers.isInIntro(119.5, tailTolerance: 1))
        XCTAssertFalse(markers.isInIntro(120, tailTolerance: 1))
        XCTAssertFalse(PlaybackMarkers.none.isInIntro(60, tailTolerance: 1))
    }

    func testUpNextTriggerPrefersCreditsThenFallsBack() {
        let withCredits = PlaybackMarkers(intro: nil, creditsStart: 1320)
        XCTAssertEqual(withCredits.upNextTrigger(duration: 1440, fallbackLead: 10), 1320)

        XCTAssertEqual(PlaybackMarkers.none.upNextTrigger(duration: 1440, fallbackLead: 10), 1430)

        // 片尾标记晚于时长(脏数据)→ 退回兜底
        let bogus = PlaybackMarkers(intro: nil, creditsStart: 2000)
        XCTAssertEqual(bogus.upNextTrigger(duration: 1440, fallbackLead: 10), 1430)

        // 时长未知时不猜
        XCTAssertNil(withCredits.upNextTrigger(duration: 0, fallbackLead: 10))
        // 比兜底提前量还短的片子:从 0 起就提示,不出现负数
        XCTAssertEqual(PlaybackMarkers.none.upNextTrigger(duration: 5, fallbackLead: 10), 0)
    }

    func testCreditsAtZeroIsIgnored() {
        XCTAssertNil(PlaybackMarkers(chapters: [chapter(0, "CreditsStart")]).creditsStart)
    }

    // MARK: - 续播回退

    func testResumePositionRewindsButNeverBelowZero() {
        XCTAssertEqual(PlaybackRules.resumePosition(from: 0), 0)
        XCTAssertEqual(PlaybackRules.resumePosition(from: 3), 0)
        XCTAssertEqual(PlaybackRules.resumePosition(from: 100), 100 - Metrics.resumeRewind)
    }

    /// DirectStream 续播时,到达续播点之前的位置(文件开头)不可信 ——
    /// 此时上报会把服务端进度改回 0。
    func testSettledPositionOnlyWaitsForDirectStreamResume() {
        XCTAssertFalse(PlaybackRules.isSettledPosition(0, startSeconds: 595, method: .directStream))
        XCTAssertTrue(PlaybackRules.isSettledPosition(594, startSeconds: 595, method: .directStream))
        XCTAssertTrue(PlaybackRules.isSettledPosition(0, startSeconds: 0, method: .directStream))
        XCTAssertTrue(PlaybackRules.isSettledPosition(0, startSeconds: 595, method: .transcode))
    }

    // MARK: - 统计

    func testStatisticsFormatting() {
        XCTAssertEqual(PlayerStatistics.shortCodecName("H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"), "H.264")
        XCTAssertEqual(PlayerStatistics.decoderText("no"), "软件解码")
        XCTAssertEqual(PlayerStatistics.decoderText("videotoolbox"), "硬件解码(videotoolbox)")
        XCTAssertEqual(PlayerStatistics.bitrateText("8200000"), "8.2 Mbps")
        XCTAssertEqual(PlayerStatistics.bitrateText("192000"), "192 kbps")
        XCTAssertNil(PlayerStatistics.bitrateText("0"))
        XCTAssertNil(PlayerStatistics.bitrateText("abc"))
        XCTAssertEqual(PlayerStatistics.fpsText("23.976"), "23.976 fps")
    }

    /// 实测值取自本机 mpv 0.41 播放一段 640×360 H.264 测试片的读数 ——
    /// 属性名是 mpv 的,但**这里的契约是「读不到的属性不凑『未知』」**,
    /// 与内核无关(见 `PlayerStatistics` 的注释)。
    func testStatisticsLinesSkipMissingProperties() {
        let stats = PlayerStatistics(properties: [
            "video-codec": "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10",
            "video-params/w": "640",
            "video-params/h": "360",
            "container-fps": "24",
            "hwdec-current": "no",
            "audio-codec-name": "aac",
            "audio-params/samplerate": "44100",
            "audio-params/channel-count": "1",
        ], session: nil)
        let byLabel = Dictionary(uniqueKeysWithValues: stats.lines.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["视频"], "H.264 · 640×360 · 24 fps")
        XCTAssertEqual(byLabel["解码"], "软件解码")
        XCTAssertEqual(byLabel["音频"], "aac · 44.1 kHz · 1 声道")
        XCTAssertNil(byLabel["丢帧"], "读不到的属性不凑「未知」")
        XCTAssertNil(byLabel["播放方式"], "没有会话就不显示播放方式")
    }

    // MARK: - 上一集

    func testPreviousEpisodeIsTheOneRightBefore() throws {
        let episodes = try ["E1", "E2", "E3"].map { try decodeItem(#"{"Id":"\#($0)","Name":"\#($0)","Type":"Episode"}"#) }
        XCTAssertEqual(NextEpisodeResolver.item(before: "E2", in: episodes)?.id, "E1")
        XCTAssertNil(NextEpisodeResolver.item(before: "E1", in: episodes))
        XCTAssertNil(NextEpisodeResolver.item(before: "X", in: episodes))
    }

    // MARK: - 倍速记忆(只验作用域判定,不需要播放器)

    /// 电影没有 `SeriesId`,判定键退化成「这一项自己的 `Id`」。
    /// ⚠️ 真正「记在哪 / 给谁用」的接线覆盖随 `PlayerViewModel` 一起删了。
    @MainActor
    func testSpeedScopeIDFallsBackToItemIDWithoutSeries() throws {
        XCTAssertEqual(PlaybackSpeedStore.scopeID(for: try episode("E1", series: "S1")), "S1")
        XCTAssertEqual(PlaybackSpeedStore.scopeID(for: try movie("M1")), "M1")
    }

    // MARK: - 辅助

    private func chapter(_ seconds: Double, _ marker: String) -> EmbyChapter {
        EmbyChapter(
            startPositionTicks: TickConverter.ticks(fromSeconds: seconds),
            name: marker,
            markerType: marker)
    }

    private func decodeItem(_ json: String) throws -> EmbyItem {
        try JSONDecoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

    private func episode(_ id: String, series: String) throws -> EmbyItem {
        try decodeItem(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"\#(series)"}"#)
    }

    private func movie(_ id: String) throws -> EmbyItem {
        try decodeItem(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie"}"#)
    }
}
