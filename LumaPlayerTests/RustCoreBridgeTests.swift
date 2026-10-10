import XCTest
@testable import LumaPlayer

/// P1 门禁：Rust 核心真的能从 Swift 调到。
///
/// 为什么要有这个文件：`xcodebuild build` 通过**证明不了** FFI 边界是通的 ——
/// 边界接错了照样编译得过，要到运行时才炸（符号找不到、ABI 对不上）。
/// 所以这里必须真的调过去、拿到值、再校验。
///
/// 详见 `docs/DECISIONS/rust-core-xcode-integration.md`。
final class RustCoreBridgeTests: XCTestCase {

    /// 结构化返回值（UniFFI `Record`）能过边界。
    func testCoreInfoCrossesTheBoundary() {
        let info = coreInfo()

        XCTAssertEqual(info.version, "0.1.0")
        XCTAssertTrue(
            info.apiContract.contains("API_CONTRACT.md"),
            "apiContract 实际值：\(info.apiContract)"
        )
    }

    /// `String` 双向过边界，含非 ASCII。
    func testEchoRoundTripsIncludingNonASCII() {
        XCTAssertEqual(echo(message: "hello"), "hello")
        XCTAssertEqual(echo(message: "峰哥"), "峰哥")
        XCTAssertEqual(echo(message: ""), "")
    }

    /// 跨 crate 连通性：`luma-ffi → luma-emby` 的依赖真的链上了。
    ///
    /// 这条还顺带守住一条硬规则：未登录时 `Authorization` 头里**不允许**出现
    /// `UserId` 段（⛔ 不能写成空字符串）。
    func testEmbyAuthorizationHeaderBuiltByRust() {
        let loggedOut = embyAuthorizationHeader(
            device: "192.168.1.10",
            deviceId: "0123456789abcdef",
            version: "0.1.0",
            userId: nil
        )
        XCTAssertFalse(loggedOut.contains("UserId"), "未登录时不应出现 UserId：\(loggedOut)")
        XCTAssertFalse(loggedOut.contains("Token"), "token 不该进 Authorization 头：\(loggedOut)")

        let loggedIn = embyAuthorizationHeader(
            device: "192.168.1.10",
            deviceId: "0123456789abcdef",
            version: "0.1.0",
            userId: "user-42"
        )
        XCTAssertTrue(
            loggedIn.hasPrefix("Emby UserId=\"user-42\""),
            "已登录时 UserId 应排在最前：\(loggedIn)"
        )
    }

    /// 非 ASCII 的 Device 会在 Rust 侧被清洗掉（部分服务器见到非 ASCII 直接 400）。
    func testNonASCIIDeviceIsSanitisedOnTheRustSide() {
        let header = embyAuthorizationHeader(
            device: "峰哥的-Mac",
            deviceId: "0123456789abcdef",
            version: "0.1.0",
            userId: nil
        )
        XCTAssertTrue(header.contains("Device=\"Mac\""), "实际值：\(header)")
    }
}
