import XCTest
@testable import LumaPlayer

/// 凭据脱敏(CLAUDE.md「安全与隐私」;docs/PITFALLS.md Q9)。
///
/// 播放地址可能带 `api_key` 退路(API_CONTRACT.md 6.2),
/// 任何进日志的文本都必须先过 `SecretRedactor`。
final class SecretRedactorTests: XCTestCase {

    func testRedactsAPIKeyInQueryString() {
        let input = "https://emby.test/emby/videos/x/master.m3u8?api_key=SECRET123&DeviceId=abc"
        let output = SecretRedactor.redacted(input)

        XCTAssertFalse(output.contains("SECRET123"))
        XCTAssertTrue(output.contains("api_key=<redacted>"))
        // 非敏感参数必须保留,否则日志就失去诊断价值
        XCTAssertTrue(output.contains("DeviceId=abc"))
    }

    func testRedactsTokenHeader() {
        let output = SecretRedactor.redacted("X-Emby-Token: SECRET-TOKEN\nHost: emby.test")

        XCTAssertFalse(output.contains("SECRET-TOKEN"))
        XCTAssertTrue(output.contains("X-Emby-Token: <redacted>"))
        XCTAssertTrue(output.contains("Host: emby.test"))
    }

    /// Emby 的 Authorization 值自带空格与逗号,必须整行替换,
    /// 不能只替换到第一个分隔符。
    func testRedactsAuthorizationHeaderEntireLine() {
        let value = #"Emby UserId="0123", Client="LumaPlayer", Device="Mac", Version="0.1""#
        let output = SecretRedactor.redacted("Authorization: \(value)\nAccept: application/json")

        XCTAssertFalse(output.contains("0123"))
        XCTAssertTrue(output.contains("Authorization: <redacted>"))
        XCTAssertTrue(output.contains("Accept: application/json"))
    }

    func testRedactsPasswordField() {
        let output = SecretRedactor.redacted(#"{"Username":"alice","Pw":"hunter2"}"#)

        XCTAssertFalse(output.contains("hunter2"))
        XCTAssertTrue(output.contains("Pw"))
    }

    func testRedactedDescriptionKeepsPathAndDropsCredentials() throws {
        let url = try XCTUnwrap(URL(
            string: "https://alice:hunter2@emby.test/emby/Videos/ITEM/stream.mkv"
                + "?static=true&api_key=SECRET123&PlaySessionId=PS-1"))

        let description = SecretRedactor.redactedDescription(of: url)

        XCTAssertFalse(description.contains("hunter2"))
        XCTAssertFalse(description.contains("SECRET123"))
        XCTAssertTrue(description.contains("/emby/Videos/ITEM/stream.mkv"))
        XCTAssertTrue(description.contains("PlaySessionId=PS-1"))
        // 占位串带尖括号,URLComponents 会把它百分号编码,所以只断言
        // 「这个参数的值已被替换」,不写死编码后的字面量。
        XCTAssertTrue(description.contains("api_key="))
        XCTAssertTrue(description.contains("redacted"))
    }

    func testIsSensitiveIsCaseInsensitive() {
        XCTAssertTrue(SecretRedactor.isSensitive("API_Key"))
        XCTAssertTrue(SecretRedactor.isSensitive("X-Emby-Token"))
        XCTAssertFalse(SecretRedactor.isSensitive("PlaySessionId"))
    }
}
