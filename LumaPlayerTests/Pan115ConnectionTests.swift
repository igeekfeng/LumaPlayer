import XCTest
@testable import LumaPlayer

/// `Pan115Connection` 里不发网络请求的部分:授权状态、片库根、路径归一化与 `path → cid` 索引。
///
/// ⚠️ 列目录 / 取直链 / 扫码登录需要真实 115 账号,**未在真实服务器验证**;
/// 这些路径的行为只能靠 `Pan115DecodingTests`(线格式)与 `Pan115EndpointTests`(请求形状)间接锁住。
final class Pan115ConnectionTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!
    private var connection: Pan115Connection!
    private let sourceID = UUID()

    override func setUp() {
        super.setUp()
        MockEmbyURLProtocol.reset()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
        connection = Pan115Connection(
            credentials: credentials,
            client: Pan115APIClient(
                session: MockEmbyURLProtocol.makeSession(),
                limiter: Pan115RateLimiter(minimumInterval: .zero)))
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        connection = nil
        try await super.tearDown()
    }

    // MARK: - 授权状态(只读凭据文件)

    /// 没 Cookie 时是一屏引导,不是错误。
    func testAuthorizationNeedsAuthorizationWithoutCredential() async throws {
        let state = try await connection.authorization()
        XCTAssertEqual(state, .needsAuthorization)
        XCTAssertFalse(state.isAuthorized)
        XCTAssertNil(state.account)
    }

    /// 有 Cookie 就算已授权,账号信息是可选快照(要另发一次 `nav` 才有)。
    func testAuthorizationIsAuthorizedWithCredential() async throws {
        let credential = Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil)
        try await credentials.savePan115Credential(credential)

        let state = try await connection.authorization()
        XCTAssertTrue(state.isAuthorized)
        XCTAssertEqual(state, .authorized(credential: credential, account: nil))
        XCTAssertNil(state.account, "⛔ 不得编占位账号:昵称要发 nav 才有")
    }

    /// 取凭据失败要抛 `notAuthorized`,⛔ 不能返回空串让上层拼出畸形 Cookie 头。
    func testCredentialThrowsWhenMissing() async throws {
        do {
            _ = try await connection.credential()
            XCTFail("没 Cookie 时应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .notAuthorized)
            XCTAssertTrue(error.needsAuthorization)
        }
    }

    // MARK: - 片库根(按来源存)

    func testLibraryRootStartsNil() async throws {
        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(root)
    }

    func testLibraryRootRoundTrips() async throws {
        let root = Pan115LibraryRoot(path: "/影视/电影", name: "电影")
        try await connection.setLibraryRoot(root, for: sourceID)
        let stored = try await connection.libraryRoot(for: sourceID)
        XCTAssertEqual(stored, root)
    }

    /// 片库根按来源隔离:两个 115 来源各有自己的起点。
    func testLibraryRootIsPerSource() async throws {
        let other = UUID()
        try await connection.setLibraryRoot(Pan115LibraryRoot(path: "/A", name: "A"), for: sourceID)
        let otherRoot = try await connection.libraryRoot(for: other)
        XCTAssertNil(otherRoot)
    }

    /// `nil` = 明确清空(回到网盘根),不是「没设置过」。
    func testSettingNilClearsLibraryRoot() async throws {
        try await connection.setLibraryRoot(Pan115LibraryRoot(path: "/A", name: "A"), for: sourceID)
        try await connection.setLibraryRoot(nil, for: sourceID)
        let cleared = try await connection.libraryRoot(for: sourceID)
        XCTAssertNil(cleared)
    }

    // MARK: - 登出

    /// 登出只删 Cookie,**保留片库根** —— 重新扫码后还在原目录。
    func testSignOutKeepsLibraryRoots() async throws {
        try await credentials.savePan115Credential(
            Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil))
        try await connection.setLibraryRoot(Pan115LibraryRoot(path: "/A", name: "A"), for: sourceID)

        try await connection.signOut()

        let state = try await connection.authorization()
        XCTAssertEqual(state, .needsAuthorization)
        let root = try await connection.libraryRoot(for: sourceID)
        XCTAssertEqual(root, Pan115LibraryRoot(path: "/A", name: "A"))
    }

    // MARK: - 删除(§9)

    /// 删除按 id 走 `POST /rb/delete`;响应必须是 `state:1`。
    func testDeletingAFileSendsItsID() async throws {
        try await credentials.savePan115Credential(
            Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil))
        MockEmbyURLProtocol.stub(
            .json(#"{"state":1}"#), host: "webapi.115.com", path: "/rb/delete")

        try await connection.deleteFile(id: "987")

        let request = try XCTUnwrap(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/rb/delete"))
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(request.body), as: UTF8.self),
            "fid%5B0%5D=987")
    }

    /// 没 Cookie 时连请求都不发(删除是写操作,⛔ 不拿空凭据去撞)。
    func testDeletingWithoutCredentialThrowsNotAuthorized() async {
        do {
            try await connection.deleteFile(id: "1")
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .notAuthorized)
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// 空 id 不发请求:没有可删对象时说清楚,⛔ 不交给服务端猜。
    func testDeletingEmptyIDIsRejectedWithoutNetwork() async {
        do {
            try await connection.deleteFile(id: "")
            XCTFail("应当抛错")
        } catch let error as Pan115Error {
            XCTAssertEqual(error, .invalidRequest("这一条没有可用的文件 ID"))
        } catch {
            XCTFail("错误的类型:\(error)")
        }
        XCTAssertTrue(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    /// `231011`「已删除」是幂等成功:目标状态已经达成,⛔ 不报错、不重发。
    func testDeletingAlreadyDeletedFileSucceedsIdempotently() async throws {
        try await credentials.savePan115Credential(
            Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil))
        MockEmbyURLProtocol.stub(
            .json(#"{"state":0,"errno":231011,"error":"文件已删除，请勿重复操作"}"#),
            host: "webapi.115.com", path: "/rb/delete")

        try await connection.deleteFile(id: "1")

        XCTAssertEqual(
            MockEmbyURLProtocol.recordedRequests().filter { $0.url.path == "/rb/delete" }.count,
            1, "⛔ 幂等成功不重发")
    }

    // MARK: - 路径工具

    /// 根目录的拼接不能产生双斜杠 —— 否则 `path → cid` 索引键与浏览页的路径对不上。
    func testChildPathNeverProducesDoubleSlash() {
        XCTAssertEqual(Pan115Connection.childPath("电影", of: "/"), "/电影")
        XCTAssertEqual(Pan115Connection.childPath("电影", of: "/影视"), "/影视/电影")
    }

    /// 索引键必须统一:尾部斜杠、空白、空串都要归一化,否则同一个目录会有多个键。
    func testNormalizedPathFoldsTrailingSlashesAndBlank() {
        XCTAssertEqual(Pan115Connection.normalizedPath(""), "/")
        XCTAssertEqual(Pan115Connection.normalizedPath("   "), "/")
        XCTAssertEqual(Pan115Connection.normalizedPath("/"), "/")
        XCTAssertEqual(Pan115Connection.normalizedPath("/影视"), "/影视")
        XCTAssertEqual(Pan115Connection.normalizedPath("/影视/"), "/影视")
        XCTAssertEqual(Pan115Connection.normalizedPath("/影视///"), "/影视")
        XCTAssertEqual(Pan115Connection.normalizedPath(" /影视 "), "/影视")
    }

    /// 根目录直接返回 `cid=0`,不发 `files/getid`(省一次请求 = 少一次风控面,§6)。
    func testRootDirectoryIDIsZeroWithoutNetwork() async throws {
        // 没凭据也会先短路:根目录不需要 Cookie 就能回答
        let cid = try await connection.directoryID(path: "/")
        XCTAssertEqual(cid, "0")
    }

    func testRootDirectoryIDNormalizesTrailingSlash() async throws {
        let blank = try await connection.directoryID(path: "")
        XCTAssertEqual(blank, "0")
        let slashes = try await connection.directoryID(path: "///")
        XCTAssertEqual(slashes, "0")
    }

    // MARK: - 片库根类型

    func testRootLibraryRootShape() {
        XCTAssertTrue(Pan115LibraryRoot.root.isRoot)
        XCTAssertEqual(Pan115LibraryRoot.root.path, "/")
        // 根没有目录名,展示成「115 网盘」
        XCTAssertEqual(Pan115LibraryRoot.root.displayName, "115 网盘")

        let nested = Pan115LibraryRoot(path: "/影视", name: "影视")
        XCTAssertFalse(nested.isRoot)
        XCTAssertEqual(nested.displayName, "影视")
    }
}
