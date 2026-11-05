import XCTest
@testable import LumaPlayer

/// 轨道标记(评论 / 原声 / 听障)从 `track-list` 解到 `MPVTrack`,并出现在菜单副标题里(MPV_INTEGRATION.md §7)。
@MainActor
final class MPVTrackFlagsTests: XCTestCase {

    func testDetailListsFlagsAfterCodecAndExternal() {
        var track = MPVTrack(id: 2, type: .audio, selected: false, title: "Commentary", lang: "eng",
                             codec: "aac", isExternal: true, isForced: false)
        track.isCommentary = true
        track.isOriginal = true
        track.isHearingImpaired = true
        XCTAssertEqual(track.detail, "AAC · 外挂 · 评论 · 原声 · 听障")
    }

    func testDetailWithoutFlagsIsUnchanged() {
        let track = MPVTrack(id: 1, type: .audio, selected: true, title: nil, lang: nil,
                             codec: "aac", isExternal: false, isForced: false)
        XCTAssertEqual(track.detail, "AAC")
    }

    func testFlagsOnlyStillProduceDetail() {
        var track = MPVTrack(id: 1, type: .sub, selected: false, title: nil, lang: nil,
                             codec: nil, isExternal: false, isForced: false)
        track.isHearingImpaired = true
        XCTAssertEqual(track.detail, "听障")
    }

    /// 真实 libmpv 读合成 mkv:第一条音轨 original、第二条 comment、字幕 hearing_impaired。不需要 GPU。
    /// 重新生成(仓库根执行,`sdh.srt` 是任意一条 SRT 字幕):
    ///
    ///     ffmpeg -y -f lavfi -i color=c=black:s=64x36:r=12:d=1 -f lavfi -i sine=f=440:d=1 \
    ///       -f lavfi -i sine=f=660:d=1 -i sdh.srt -map 0 -map 1 -map 2 -map 3 \
    ///       -c:v libx264 -preset ultrafast -c:a aac -b:a 32k -c:s srt -map_metadata -1 \
    ///       -fflags +bitexact -flags:v +bitexact -flags:a +bitexact \
    ///       -disposition:a:0 default+original -disposition:a:1 comment -metadata:s:a:1 title=Commentary \
    ///       -disposition:s:0 hearing_impaired LumaPlayerTests/Fixtures/Media/track_flags_synthetic.mkv
    func testLibmpvExposesContainerTrackFlags() async throws {
        let url = try XCTUnwrap(fixtureURL("track_flags_synthetic.mkv"), "找不到 fixture")
        let player = MPVPlayer()
        defer { player.shutdown() }
        try XCTSkipIf(player.initializationFailure != nil, "libmpv 初始化失败:\(player.initializationFailure ?? "")")

        var latest: [MPVTrack] = []
        let arrived = expectation(description: "track-list 带两条音轨 + 一条字幕")
        arrived.assertForOverFulfill = false
        player.attach(eventBridge: MPVEventBridge { event in
            guard case .trackList(let tracks) = event else { return }
            latest = tracks
            if tracks.filter({ $0.type == .audio }).count == 2, tracks.contains(where: { $0.type == .sub }) {
                arrived.fulfill()
            }
        })
        try player.load(url: url, headers: [:])
        await fulfillment(of: [arrived], timeout: 5)

        let audio = latest.filter { $0.type == .audio }
        XCTAssertEqual(audio.map(\.isOriginal), [true, false])
        XCTAssertEqual(audio.map(\.isCommentary), [false, true])
        let sub = try XCTUnwrap(latest.first { $0.type == .sub })
        XCTAssertTrue(sub.isHearingImpaired)
        XCTAssertFalse(sub.isCommentary)
    }

    /// 测试 bundle 里资源可能被展平,也可能保留子目录。
    private func fixtureURL(_ name: String) -> URL? {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: name, withExtension: nil) { return url }
        let root = URL(fileURLWithPath: bundle.resourcePath ?? bundle.bundlePath)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }
}
