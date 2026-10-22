import XCTest
@testable import LumaPlayer

/// `BaiduPanSessionPreparer` 不联网就能测的部分。真实取流(设备码 → `dlink` → `method=streaming`)需要真网盘账号,未验证。
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

    /// 百度没有起流位置参数:⛔ 不能静默从 0 重开(用户拖到 30 分钟却看到 0:00,进度还会被写成 0),必须报错。
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

    func testAuthoritativeDurationIsNilBeforeFetching() async throws {
        let preparer = makePreparer()
        let duration = await preparer.authoritativeDurationSeconds
        XCTAssertNil(duration)
    }
}
