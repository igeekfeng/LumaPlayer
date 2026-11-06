import XCTest
@testable import LumaPlayer

/// `Pan115SessionPreparer` 的行为:起流位置拒绝、`pick_code` 回落、直链每次重取。
/// 桩按 `scheme|host|path` 打,所以 115 的真实主机名可以原样用。
/// `makeSession` 只覆盖失败与回落分支:取直链的响应要用客户端那一次的随机 key 加密,桩造不出合法密文
/// (见 `Pan115APIClientTests` 的同类说明)。
final class Pan115SessionPreparerTests: XCTestCase {
    private var store: CredentialStore!
    private var connection: Pan115Connection!
    private var pickCodes: Pan115PickCodeCache!

    private let file = BaiduPanFile(
        fsID: 42,
        path: "/影视/a.mp4",
        name: "a.mp4",
        sizeBytes: 1024,
        isDirectory: false,
        category: BaiduPanCategory.video,
        modifiedAt: nil,
        thumbnailURL: nil
    )

    override func setUp() async throws {
        try await super.setUp()
        MockEmbyURLProtocol.reset()
        let storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        store = CredentialStore(storage: storage)
        try await store.savePan115Credential(
            Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil))
        connection = Pan115Connection(
            credentials: store,
            client: Pan115APIClient(
                session: MockEmbyURLProtocol.makeSession(),
                limiter: Pan115RateLimiter(minimumInterval: .zero))
        )
        pickCodes = Pan115PickCodeCache()
    }

    override func tearDown() async throws {
        MockEmbyURLProtocol.reset()
        store = nil
        connection = nil
        pickCodes = nil
        try await super.tearDown()
    }

    /// 115 的直链没有起流位置参数 ⇒ 带值必须抛错,⛔ 不从 0 重开(会把进度写成 0)。
    func testStartTimeTicksIsRejected() async {
        let preparer = Pan115SessionPreparer(
            connection: connection, file: file, pickCodes: pickCodes)
        do {
            _ = try await preparer.makeSession(startTimeTicks: 10_000_000)
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .playbackUnsupported("115 网盘的播放流不支持从指定位置起流(没有对位的起流参数)。"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
    }

    /// 缓存里没有 `pick_code` 时列一次父目录补上;补不到就如实抛 `pickCodeMissing`。
    func testMissingPickCodeFallsBackToDirectoryListing() async {
        // `files/getid` 把 "/影视" 换成 cid,`files` 返回同目录的另一个文件(不含 a.mp4)
        MockEmbyURLProtocol.stub(
            .json(#"{"state":1,"cid":"999"}"#), host: "webapi.115.com", path: "/files/getid")
        MockEmbyURLProtocol.stub(
            .json(#"{"state":1,"cid":"999","count":1,"data":[{"fid":"7","cid":"999","n":"b.mp4","s":"1","pc":"PC7","iv":"1"}]}"#),
            host: "webapi.115.com", path: "/files")

        let preparer = Pan115SessionPreparer(
            connection: connection, file: file, pickCodes: pickCodes)
        do {
            _ = try await preparer.makeSession()
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .pickCodeMissing("a.mp4"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        // 列目录时把整层的 pick_code 都补进了缓存(省下一次请求)
        let cached = await pickCodes.pickCode(for: 7)
        XCTAssertEqual(cached, "PC7")
    }

    /// 父目录列出来也找不到这个文件时,⛔ 不要拿别的文件的 `pick_code` 顶替。
    func testUnrelatedFilesInDirectoryAreNotUsed() async {
        MockEmbyURLProtocol.stub(
            .json(#"{"state":1,"cid":"999"}"#), host: "webapi.115.com", path: "/files/getid")
        MockEmbyURLProtocol.stub(
            .json(#"{"state":1,"cid":"999","count":0,"data":[]}"#),
            host: "webapi.115.com", path: "/files")

        let preparer = Pan115SessionPreparer(
            connection: connection, file: file, pickCodes: pickCodes)
        do {
            _ = try await preparer.makeSession()
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .pickCodeMissing("a.mp4"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        let cached = await pickCodes.pickCode(for: 7)
        XCTAssertNil(cached)
    }

    /// 缓存里已有 `pick_code` 时不该再列目录(§6 限速,能省一次就省一次)。
    func testCachedPickCodeSkipsDirectoryListing() async {
        await pickCodes.store("PC42", for: 42)
        MockEmbyURLProtocol.stub(
            .json(#"{"state":0,"errno":990001,"error":"请重新登录"}"#),
            host: "proapi.115.com", path: "/app/chrome/downurl")

        let preparer = Pan115SessionPreparer(
            connection: connection, file: file, pickCodes: pickCodes)
        _ = try? await preparer.makeSession()

        let paths = MockEmbyURLProtocol.recordedRequests().map(\.url.path)
        XCTAssertTrue(paths.contains("/app/chrome/downurl"))
        XCTAssertFalse(paths.contains("/files"), "不该为了取 pick_code 再列一次目录")
        XCTAssertFalse(paths.contains("/files/getid"))
    }

    /// 起播位置被拒时**不发任何网络请求**(判断在取链之前)。
    func testStartTimeRejectionHappensBeforeAnyNetwork() async {
        let preparer = Pan115SessionPreparer(
            connection: connection, file: file, pickCodes: pickCodes)
        _ = try? await preparer.makeSession(startTimeTicks: 1)
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// `authoritativeDurationSeconds` 恒为 nil(115 的列表接口不给时长),⛔ 不编一个数出来。
    func testAuthoritativeDurationStaysNil() async {
        let preparer = Pan115SessionPreparer(
            connection: connection, file: file, pickCodes: pickCodes)
        let duration = await preparer.authoritativeDurationSeconds
        XCTAssertNil(duration)
    }
}
