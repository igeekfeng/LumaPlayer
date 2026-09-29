import XCTest
@testable import LumaPlayer

/// isLocalOrPrivateHost 测试:判定表见 API_CONTRACT.md 1.4。
/// 该函数是局域网 http 回退的前提条件,必须纯函数可单测。
final class LocalHostDetectionTests: XCTestCase {

    // MARK: - 命中

    func testLocalhost() {
        XCTAssertTrue(isLocalOrPrivateHost("localhost"))
    }

    func testLocalhostUppercase() {
        XCTAssertTrue(isLocalOrPrivateHost("LocalHost"))
    }

    func testDotLocalSuffix() {
        XCTAssertTrue(isLocalOrPrivateHost("emby.local"))
    }

    func testDotLocalSuffixUppercase() {
        XCTAssertTrue(isLocalOrPrivateHost("Emby.LOCAL"))
    }

    func testLoopbackIPv4() {
        XCTAssertTrue(isLocalOrPrivateHost("127.0.0.1"))
    }

    func testTenDotIPv4() {
        XCTAssertTrue(isLocalOrPrivateHost("10.1.2.3"))
    }

    func testPrivate172RangeStart() {
        XCTAssertTrue(isLocalOrPrivateHost("172.16.0.1"))
    }

    func testPrivate172RangeEnd() {
        XCTAssertTrue(isLocalOrPrivateHost("172.31.255.255"))
    }

    func testPrivate192Dot168() {
        XCTAssertTrue(isLocalOrPrivateHost("192.168.1.10"))
    }

    func testLinkLocal169Dot254() {
        XCTAssertTrue(isLocalOrPrivateHost("169.254.1.1"))
    }

    func testIPv6Loopback() {
        XCTAssertTrue(isLocalOrPrivateHost("::1"))
    }

    func testIPv6LinkLocal() {
        XCTAssertTrue(isLocalOrPrivateHost("fe80::1"))
    }

    func testIPv6UniqueLocalFC() {
        XCTAssertTrue(isLocalOrPrivateHost("fc00::1"))
    }

    func testIPv6UniqueLocalFD() {
        XCTAssertTrue(isLocalOrPrivateHost("fd12:3456:789a::1"))
    }

    // MARK: - 不命中

    func testPublicDomain() {
        XCTAssertFalse(isLocalOrPrivateHost("example.com"))
    }

    func testPublicIPv4() {
        XCTAssertFalse(isLocalOrPrivateHost("8.8.8.8"))
    }

    func testJustAbove172Range() {
        XCTAssertFalse(isLocalOrPrivateHost("172.32.0.1"))
    }

    func testJustBelow172Range() {
        XCTAssertFalse(isLocalOrPrivateHost("172.15.255.255"))
    }

    func testJustOutside192Dot168() {
        XCTAssertFalse(isLocalOrPrivateHost("192.169.1.1"))
    }

    func testIPv6Global() {
        XCTAssertFalse(isLocalOrPrivateHost("2001:4860::1"))
    }

    func testBareLocalWithoutDot() {
        // ".local 结尾"要求有点;裸 local 是公网可注册名,不命中
        XCTAssertFalse(isLocalOrPrivateHost("local"))
    }
}
