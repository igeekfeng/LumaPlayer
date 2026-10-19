import CryptoKit
import XCTest
@testable import LumaPlayer

/// 媒体指纹(`DanmakuFingerprint`)。
///
/// 这块的风险全在**边界**上:真实服务器上没法构造「服务端忽略 Range 回了整个文件」
/// 这种响应,所以拒绝分支只能离线覆盖 —— 每一条都对应一个真实会遇到的服务器行为。
///
/// ⛔ **零真实网络**:全走 `MockEmbyURLProtocol`。
final class DanmakuFingerprintTests: XCTestCase {

    private let mediaURL = URL(string: "https://emby.test/emby/videos/1/stream.mkv?static=true")!
    private let headers = ["X-Emby-Token": "token-value"]
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        session = MockEmbyURLProtocol.makeSession()
    }

    override func tearDown() {
        MockEmbyURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    /// 算出 MD5 并返回 32 位小写 hex。期望值用 CryptoKit 独立算,不复用被测实现。
    ///
    /// 用「整个文件都在 16 MiB 窗口内」的形状:此时 `Content-Range` 的 end
    /// 应当正好是 `total - 1`,与实现里的 `min(16 MiB, total) - 1` 对齐。
    func testComputesMD5OfTheWholeFileWhenItFitsInWindow() async throws {
        let payload = Data(repeating: 0x5A, count: 64 * 1024)
        MockEmbyURLProtocol.stub(
            .bytes(payload, statusCode: 206,
                   headers: ["Content-Range": "bytes 0-\(payload.count - 1)/\(payload.count)"]),
            path: mediaURL.path)

        let hash = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers,
            expectedFileSize: Int64(payload.count), session: session)

        let expected = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
        XCTAssertEqual(hash?.count, 32)
    }

    /// 请求必须带 `Range: bytes=0-16777215` 与播放用的认证头。
    func testRequestCarriesRangeAndPlaybackHeaders() async throws {
        let payload = Data(repeating: 1, count: 1024)
        MockEmbyURLProtocol.stub(
            .bytes(payload, statusCode: 206,
                   headers: ["Content-Range": "bytes 0-1023/2048"]),
            path: mediaURL.path)

        _ = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: 2048, session: session)

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.recordedRequests().first { $0.url.path == mediaURL.path })
        XCTAssertEqual(request.header("Range"), "bytes=0-16777215")
        XCTAssertEqual(request.header("X-Emby-Token"), "token-value")
    }

    /// 服务端忽略 Range 回 200 且文件 > 16 MiB → 拒绝。
    ///
    /// 这是最重要的一条:接受它就等于为算指纹把整部电影下载一遍。
    func testRejectsFullBodyForLargeFile() async throws {
        let payload = Data(repeating: 2, count: 1024)
        MockEmbyURLProtocol.stub(.bytes(payload, statusCode: 200), path: mediaURL.path)

        let hash = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: 4 * 1024 * 1024 * 1024,
            session: session)
        XCTAssertNil(hash, "整文件远大于 16 MiB 时必须拒绝,否则会把整部片下下来")
    }

    /// 文件本身 ≤ 16 MiB 时,200 全量是安全的(收到的就是全部)。
    func testAcceptsFullBodyWhenFileFitsInWindow() async throws {
        let payload = Data(repeating: 3, count: 2048)
        MockEmbyURLProtocol.stub(.bytes(payload, statusCode: 200), path: mediaURL.path)

        let hash = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: 2048, session: session)
        let expected = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
    }

    /// `Content-Range` 起点不是 0 → 拒绝(那不是文件开头,MD5 无意义)。
    func testRejectsRangeNotStartingAtZero() async throws {
        let payload = Data(repeating: 4, count: 1024)
        MockEmbyURLProtocol.stub(
            .bytes(payload, statusCode: 206,
                   headers: ["Content-Range": "bytes 1024-2047/8192"]),
            path: mediaURL.path)

        let hash = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: 8192, session: session)
        XCTAssertNil(hash)
    }

    /// 服务端给的总长与 `MediaSource.Size` 不一致 → 拒绝(不是同一个文件)。
    func testRejectsSizeMismatch() async throws {
        let payload = Data(repeating: 5, count: 1024)
        MockEmbyURLProtocol.stub(
            .bytes(payload, statusCode: 206,
                   headers: ["Content-Range": "bytes 0-1023/4096"]),
            path: mediaURL.path)

        let hash = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: 8192, session: session)
        XCTAssertNil(hash)
    }

    /// 收到的字节数与 `Content-Range` 声明的长度不符 → 拒绝(截断的响应)。
    func testRejectsTruncatedBody() async throws {
        let payload = Data(repeating: 6, count: 512)  // 声明 1024,只给 512
        MockEmbyURLProtocol.stub(
            .bytes(payload, statusCode: 206,
                   headers: ["Content-Range": "bytes 0-1023/4096"]),
            path: mediaURL.path)

        let hash = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: 4096, session: session)
        XCTAssertNil(hash)
    }

    /// 网络错误 / 非 2xx → nil(调用方退回文件名匹配,⛔ 不打断播放)。
    func testNetworkFailureYieldsNil() async {
        MockEmbyURLProtocol.stub(.failure(.timedOut), path: mediaURL.path)
        let hash = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: nil, session: session)
        XCTAssertNil(hash)

        MockEmbyURLProtocol.reset()
        MockEmbyURLProtocol.stub(.status(403), path: mediaURL.path)
        let forbidden = await DanmakuFingerprint.md5(
            of: mediaURL, headers: headers, expectedFileSize: nil, session: session)
        XCTAssertNil(forbidden)
    }

    /// 非 HTTP(S) 地址直接放弃(不该拿它去请求)。
    func testRejectsNonHTTPScheme() async {
        let fileURL = URL(fileURLWithPath: "/tmp/movie.mkv")
        let hash = await DanmakuFingerprint.md5(
            of: fileURL, headers: headers, expectedFileSize: nil, session: session)
        XCTAssertNil(hash)
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    // MARK: - Content-Range 解析

    func testContentRangeParsing() {
        let full = DanmakuFingerprint.ContentRange("bytes 0-16777215/123456789")
        XCTAssertEqual(full?.start, 0)
        XCTAssertEqual(full?.end, 16_777_215)
        XCTAssertEqual(full?.total, 123_456_789)

        // `*` 总长
        let unknown = DanmakuFingerprint.ContentRange("bytes 0-1023/*")
        XCTAssertNil(unknown?.total)
        XCTAssertEqual(unknown?.end, 1023)

        // 畸形输入一律 nil,不猜
        XCTAssertNil(DanmakuFingerprint.ContentRange("bytes 1024-1023/4096"), "end < start")
        XCTAssertNil(DanmakuFingerprint.ContentRange("items 0-1023/4096"), "单位不对")
        XCTAssertNil(DanmakuFingerprint.ContentRange("bytes 0-1023"), "缺总长段")
        XCTAssertNil(DanmakuFingerprint.ContentRange("bytes 0-4096/4096"), "end 越界")
    }
}
