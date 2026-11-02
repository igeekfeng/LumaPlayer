import XCTest
@testable import LumaPlayer

/// 115 的 Cookie 四件套(`docs/PAN115_API.md` §2.1)。
///
/// `UID` 不是纯数字:它是 `user_id_ssoent_timestamp` 三段拼接,中间那段决定 115 把请求当成哪个客户端。
/// 这里不解析它 —— 本项目只用 `web`(`A1`),但**原样保存整串**是必须的。
final class Pan115CredentialTests: XCTestCase {

    // MARK: - 解析浏览器 Cookie

    func testParsesFourPieceCookie() throws {
        let credential = try XCTUnwrap(Pan115Credential(
            cookieHeader: "UID=123_A1_1793603418; CID=abc; SEID=def; KID=ghi"))
        XCTAssertEqual(credential.uid, "123_A1_1793603418")
        XCTAssertEqual(credential.cid, "abc")
        XCTAssertEqual(credential.seid, "def")
        XCTAssertEqual(credential.kid, "ghi")
    }

    /// 浏览器复制的串常带空格、大小写混杂、还有别的 Cookie(`OOFL`, `PHPSESSID` 之类)。
    func testParsesMessyCookieString() throws {
        let credential = try XCTUnwrap(Pan115Credential(cookieHeader: """
         OOFL=hint; uid = 42_A1_1 ;  cid=CID ; PHPSESSID=x; seid = SEID ; KID=K
        """))
        XCTAssertEqual(credential.uid, "42_A1_1")
        XCTAssertEqual(credential.cid, "CID")
        XCTAssertEqual(credential.seid, "SEID")
        XCTAssertEqual(credential.kid, "K")
    }

    /// UID / CID / SEID 缺一即失败(`115driver pkg/driver/login.go:94-119` 的 `ErrBadCookie`)。
    func testMissingAnyOfTheThreeRequiredPiecesFails() {
        XCTAssertNil(Pan115Credential(cookieHeader: "CID=c; SEID=s"))
        XCTAssertNil(Pan115Credential(cookieHeader: "UID=u; SEID=s"))
        XCTAssertNil(Pan115Credential(cookieHeader: "UID=u; CID=c"))
        XCTAssertNil(Pan115Credential(cookieHeader: ""))
        XCTAssertNil(Pan115Credential(cookieHeader: "garbage"))
    }

    /// KID 可缺:老 Cookie 没有,`115driver` 也不校验它。
    func testKidIsOptional() throws {
        let credential = try XCTUnwrap(Pan115Credential(cookieHeader: "UID=u; CID=c; SEID=s"))
        XCTAssertNil(credential.kid)
    }

    /// 空值的键不算「有」(浏览器里 `KID=` 这种残项要忽略)。
    func testEmptyValueIsTreatedAsMissing() throws {
        let credential = try XCTUnwrap(Pan115Credential(cookieHeader: "UID=u; CID=c; SEID=s; KID="))
        XCTAssertNil(credential.kid)
    }

    // MARK: - 发请求用的头

    /// 顺序与 `115driver pkg/driver/login.go:122-124` 一致;KID 有才带。
    func testCookieHeaderRoundTrips() throws {
        let credential = Pan115Credential(uid: "u", cid: "c", seid: "s", kid: "k")
        XCTAssertEqual(credential.cookieHeader, "UID=u; CID=c; SEID=s; KID=k")
        XCTAssertEqual(
            try XCTUnwrap(Pan115Credential(cookieHeader: credential.cookieHeader)), credential)
    }

    func testCookieHeaderOmitsEmptyKid() {
        XCTAssertEqual(
            Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil).cookieHeader,
            "UID=u; CID=c; SEID=s")
        XCTAssertEqual(
            Pan115Credential(uid: "u", cid: "c", seid: "s", kid: "").cookieHeader,
            "UID=u; CID=c; SEID=s")
    }

    // MARK: - 扫码登录返回的对象

    /// 扫码接口的 `data.cookie` 是**大写 key** 的对象(`115driver pkg/driver/response.go:315-320`)。
    func testBuildsFromUppercaseCookieObject() throws {
        let credential = try XCTUnwrap(Pan115Credential(
            cookieObject: ["UID": "u", "CID": "c", "SEID": "s", "KID": "k"]))
        XCTAssertEqual(credential, Pan115Credential(uid: "u", cid: "c", seid: "s", kid: "k"))
    }

    func testCookieObjectWithoutSeidFails() {
        XCTAssertNil(Pan115Credential(cookieObject: ["UID": "u", "CID": "c"]))
    }

    // MARK: - 落盘形状

    /// 凭据要能进凭据文件(JSON),`kid` 为 nil 时不该写成 `"kid": null` 之外的怪形状。
    func testCodableRoundTrip() throws {
        let credential = Pan115Credential(uid: "u", cid: "c", seid: "s", kid: nil)
        let data = try JSONEncoder().encode(credential)
        XCTAssertEqual(try JSONDecoder().decode(Pan115Credential.self, from: data), credential)
    }
}
