import XCTest
@testable import LumaPlayer

/// 串流 URL 的构造(API_CONTRACT.md 4.5)。
final class PlaybackURLBuilderTests: XCTestCase {

    /// 服务端给的 DirectStreamUrl(Emby Web 4.9.5.0 抓包形态)相对 API 根,要剥掉 api_key
    func testServerProvidedDirectStreamURLAddsPrefixAndStripsAPIKey() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")

        let url = try XCTUnwrap(builder.directStreamURL(serverProvided:
            "/videos/7/original.mkv?DeviceId=DEV&MediaSourceId=MS-7&PlaySessionId=PS-7&api_key=FAKE_TOKEN_0123456789"))

        XCTAssertEqual(
            url.absoluteString,
            "https://emby.test/emby/videos/7/original.mkv?DeviceId=DEV&MediaSourceId=MS-7&PlaySessionId=PS-7")
    }

    func testServerProvidedDirectStreamURLDoesNotDoublePrefix() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test/media"), apiPathPrefix: "/emby")

        let url = try XCTUnwrap(builder.directStreamURL(serverProvided:
            "/emby/videos/7/original.mkv?MediaSourceId=MS-7"))

        XCTAssertEqual(url.absoluteString, "https://emby.test/media/emby/videos/7/original.mkv?MediaSourceId=MS-7")
    }

    func testServerProvidedDirectStreamURLWithoutPrefixAndOnlyAPIKeyQuery() throws {
        let builder = PlaybackURLBuilder(baseURL: testURL("https://emby.test"), apiPathPrefix: "")

        let url = try XCTUnwrap(builder.directStreamURL(serverProvided: "/videos/7/original.mkv?api_key=FAKE"))

        XCTAssertEqual(url.absoluteString, "https://emby.test/videos/7/original.mkv")
    }

    func testServerProvidedDirectStreamURLEmptyReturnsNil() {
        let builder = PlaybackURLBuilder(baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")
        XCTAssertNil(builder.directStreamURL(serverProvided: ""))
    }

    func testDirectStreamURLWithPrefixAndContainer() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")

        let url = try XCTUnwrap(builder.directStreamURL(
            itemID: "ITEM-1", container: "mkv",
            mediaSourceID: "MS-1", playSessionID: "PS-1"))

        XCTAssertEqual(
            url.absoluteString,
            "https://emby.test/emby/Videos/ITEM-1/stream.mkv"
            + "?static=true&MediaSourceId=MS-1&PlaySessionId=PS-1"
        )
    }

    /// 站点没有 `/emby` 前缀时不得凭空加一个(API_CONTRACT.md 1.4)
    func testDirectStreamURLWithoutPrefix() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "")

        let url = try XCTUnwrap(builder.directStreamURL(
            itemID: "ITEM-2", container: "mp4",
            mediaSourceID: "MS-2", playSessionID: "PS-2"))

        XCTAssertTrue(url.absoluteString.hasPrefix("https://emby.test/Videos/ITEM-2/stream.mp4?"))
    }

    /// 官方两种写法都列了,不猜扩展名
    func testDirectStreamURLWithoutContainer() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")

        let url = try XCTUnwrap(builder.directStreamURL(
            itemID: "ITEM-3", container: nil,
            mediaSourceID: "MS-3", playSessionID: "PS-3"))

        XCTAssertTrue(url.absoluteString.contains("/Videos/ITEM-3/stream?"))
    }

    /// PlaySessionId / ItemId 由服务端给,不做假设
    func testDirectStreamURLEncodesQueryValues() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")

        let url = try XCTUnwrap(builder.directStreamURL(
            itemID: "ITEM 4", container: "mkv",
            mediaSourceID: "MS 4", playSessionID: "PS&4"))

        XCTAssertFalse(url.absoluteString.contains("PS&4"))
        XCTAssertTrue(url.absoluteString.contains("PS%264"))
    }

    func testTranscodeURLJoinsRelativePath() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")

        let url = try XCTUnwrap(builder.transcodeURL(
            relativePath: "/emby/videos/ITEM-5/master.m3u8?VideoCodec=h264"))

        XCTAssertEqual(
            url.absoluteString,
            "https://emby.test/emby/videos/ITEM-5/master.m3u8?VideoCodec=h264")
    }

    /// 少数服务器给绝对地址:原样采用,不再拼站点根
    func testTranscodeURLKeepsAbsoluteURL() throws {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")

        let url = try XCTUnwrap(builder.transcodeURL(
            relativePath: "https://cdn.example.com/hls/ITEM-6.m3u8"))

        XCTAssertEqual(url.absoluteString, "https://cdn.example.com/hls/ITEM-6.m3u8")
    }

    func testTranscodeURLRejectsEmptyPath() {
        let builder = PlaybackURLBuilder(
            baseURL: testURL("https://emby.test"), apiPathPrefix: "/emby")

        XCTAssertNil(builder.transcodeURL(relativePath: ""))
    }
}
