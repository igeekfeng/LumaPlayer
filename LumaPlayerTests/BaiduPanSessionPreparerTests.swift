import XCTest
@testable import LumaPlayer

/// `BaiduPanSessionPreparer`:百度来源的会话准备(不改网络就能测的部分)。
///
/// 真实取流(设备码 → `dlink` → `method=streaming`)需要真网盘账号,本机没有,
/// 按 `docs/SOURCE_ABSTRACTION_PLAN.md` §7 的约定标注「未验证」,不在这里假装覆盖。
final class BaiduPanSessionPreparerTests: XCTestCase {
    private var storage: CredentialFileStore!
    private var credentials: CredentialStore!

    override func setUp() {
        super.setUp()
        storage = CredentialFileStore(fileURL: .temporaryCredentialsFile())
        credentials = CredentialStore(storage: storage)
    }

    override func tearDown() async throws {
        try await storage.removeAll()
        storage = nil
        credentials = nil
        try await super.tearDown()
    }

    private func makeFile() -> BaiduPanFile {
        BaiduPanFile(
            fsID: 42,
            path: "/apps/LumaPlayer/a.mp4",
            name: "a.mp4",
            sizeBytes: 1024,
            isDirectory: false,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }

    private func makePreparer() -> BaiduPanSessionPreparer {
        BaiduPanSessionPreparer(
            connection: BaiduPanConnection(credentials: credentials),
            file: makeFile()
        )
    }

    /// ★ 百度没有起流位置参数。带 `startTimeTicks` 进来必须**如实报错** ——
    /// ⛔ 不能「把流重开一遍、从 0 开始」:用户拖到 30 分钟却看到 0:00,
    /// 进度还会被写成 0(这是 `seekStrategy` 那张契约要挡住的事)。
    func testRefusesStartTimeTicksInsteadOfSilentlyRestarting() async throws {
        let preparer = makePreparer()

        do {
            _ = try await preparer.makeSession(startTimeTicks: 12345)
            XCTFail("百度流带起流位置必须报错,⛔ 不能静默从头开始")
        } catch let error as BaiduPanError {
            guard case .playbackUnsupported = error else {
                return XCTFail("应报 playbackUnsupported,实际:\(error)")
            }
        }
    }

    /// 还没取过会话时,来源不知道权威时长。
    func testAuthoritativeDurationIsNilBeforeFetching() async throws {
        let preparer = makePreparer()
        let duration = await preparer.authoritativeDurationSeconds
        XCTAssertNil(duration)
    }
}
