import XCTest
@testable import LumaPlayer

/// 115 的线格式容错(`docs/PAN115_API.md` §2 - §4)。
///
/// 115 的老毛病:同一字段在数字与字符串之间来回换、`state` 用 `1`/`0` 而不是布尔、
/// 错误码字段名有三种(`errno` / `errNo` / `code`)。这些都用真实响应形状的 JSON 固定下来。
final class Pan115DecodingTests: XCTestCase {

    // MARK: - 信封

    func testEnvelopeAcceptsNumericAndStringState() throws {
        let numeric = try decode(Pan115Envelope.self, #"{"state":1}"#)
        XCTAssertTrue(numeric.isSuccess)
        XCTAssertNil(numeric.errorCode)

        let string = try decode(Pan115Envelope.self, #"{"state":"0","errno":"990001","error":"请重新登录"}"#)
        XCTAssertFalse(string.isSuccess)
        XCTAssertEqual(string.errorCode, Pan115Code.notLoggedIn)
        XCTAssertEqual(string.errorMessage, "请重新登录")
    }

    /// `state` 还有**布尔**形态:Cookie 失效时 `files` 系列回
    /// `{"state":false,"error":"请先登录"}`(§3 实测)。只解 `Int` 会把它当 nil 静默放过,
    /// 错误响应随后落到业务解码 —— 表现是「响应里没有 cid」而不是「请重新登录」。
    func testEnvelopeAcceptsBooleanFalseState() throws {
        let boolean = try decode(Pan115Envelope.self, #"{"state":false,"error":"请先登录"}"#)
        XCTAssertFalse(boolean.isSuccess)
        XCTAssertTrue(boolean.isFailure)
        XCTAssertNil(boolean.errorCode)
        XCTAssertEqual(boolean.errorMessage, "请先登录")

        let booleanTrue = try decode(Pan115Envelope.self, #"{"state":true}"#)
        XCTAssertTrue(booleanTrue.isSuccess)
        XCTAssertFalse(booleanTrue.isFailure)

        // 没有 state 字段 = 不当失败(扫码接口自己的响应外壳不走信封判定)
        let absent = try decode(Pan115Envelope.self, #"{"data":{}}"#)
        XCTAssertFalse(absent.isSuccess)
        XCTAssertFalse(absent.isFailure)
    }

    /// 三种错误码字段的优先级:`errno` → `errNo` → `code`(`115driver pkg/driver/response.go:33-40`)。
    func testEnvelopeErrorCodePrecedence() throws {
        let all = try decode(
            Pan115Envelope.self, #"{"state":0,"errno":40101035,"errNo":990001,"code":40101017}"#)
        XCTAssertEqual(all.errorCode, 40101035)

        let errNoOnly = try decode(Pan115Envelope.self, #"{"state":0,"errNo":990001,"code":1}"#)
        XCTAssertEqual(errNoOnly.errorCode, 990001)

        let codeOnly = try decode(Pan115Envelope.self, #"{"state":0,"code":40101017}"#)
        XCTAssertEqual(codeOnly.errorCode, 40101017)
    }

    // MARK: - 登录渠道(§2.1)

    /// 默认渠道必须是 `tv`(I1):与用户常用的网页端 `web`(A1)不同 ssoent 组,才不会互踢。
    func testDefaultAuthorizationChannelIsTV() {
        XCTAssertEqual(Pan115AuthorizationApp.default, .tv)
        XCTAssertEqual(Pan115AuthorizationApp.default.rawValue, "tv")
        XCTAssertEqual(Pan115AuthorizationApp.default.ssoent, "I1")
    }

    /// 设置页按 ssoent 反查渠道名;`A1` 是改用 tv 之前留下的老 Cookie,要能单独认出来。
    func testChannelDisplayNameBySSOEnt() {
        XCTAssertEqual(Pan115AuthorizationApp.displayName(forSSOEnt: "I1"), "电视端")
        XCTAssertEqual(Pan115AuthorizationApp.displayName(forSSOEnt: "R1"), "微信小程序")
        XCTAssertEqual(Pan115AuthorizationApp.displayName(forSSOEnt: "A1"), "网页端(旧登录)")
        XCTAssertNil(Pan115AuthorizationApp.displayName(forSSOEnt: "ZZ"))
    }

    /// UID 三段的中段是 ssoent;形状不对返回 nil,⛔ 不猜。
    func testCredentialSSOEntExtraction() {
        XCTAssertEqual(
            Pan115Credential(uid: "123_I1_1793603418", cid: "c", seid: "s", kid: nil).ssoent,
            "I1")
        XCTAssertEqual(
            Pan115Credential(uid: "123_A1_1793603418", cid: "c", seid: "s", kid: nil).ssoent,
            "A1")
        XCTAssertNil(
            Pan115Credential(uid: "123", cid: "c", seid: "s", kid: nil).ssoent)
        XCTAssertNil(
            Pan115Credential(uid: "123__1793603418", cid: "c", seid: "s", kid: nil).ssoent)
    }

    // MARK: - 扫码登录(§2.2)

    /// 二维码内容在 `data.qrcode`,是**要编进二维码的文本**(`https://115.com/scan/…`),不是图片地址。
    func testQRCodeTokenDecodesSession() throws {
        let response = try decode(Pan115QRCodeTokenResponse.self, """
        {"state":1,"code":0,"data":{"uid":"UID-1","time":1793603418,"sign":"SIG",
         "qrcode":"https://115.com/scan/dg-abc"}}
        """)
        let session = try XCTUnwrap(response.data?.session)
        XCTAssertEqual(session.uid, "UID-1")
        XCTAssertEqual(session.time, 1793603418)
        XCTAssertEqual(session.sign, "SIG")
        XCTAssertEqual(session.content, "https://115.com/scan/dg-abc")
    }

    /// 字段缺失时不给半成品 session,由客户端抛 `decoding` 错误。
    func testQRCodeTokenWithoutSignYieldsNoSession() throws {
        let response = try decode(Pan115QRCodeTokenResponse.self, """
        {"state":1,"data":{"uid":"UID-1","time":1,"qrcode":"https://115.com/scan/x"}}
        """)
        XCTAssertNil(response.data?.session)
    }

    /// `status` 语义:`0` 待扫 / `1` 已扫 / `2` 可换 Cookie / `-1` 过期 / `-2` 取消。
    func testQRCodeStatusMapping() throws {
        let cases: [(Int, Pan115QRCodeStatus)] = [
            (0, .waiting), (1, .scanned), (2, .allowed), (-1, .expired), (-2, .canceled),
        ]
        for (raw, expected) in cases {
            let response = try decode(
                Pan115QRCodeStatusResponse.self, #"{"state":1,"data":{"status":\#(raw)}}"#)
            XCTAssertEqual(response.data?.value, expected, "status=\(raw)")
        }
        // 认不出的码原样带出,⛔ 不猜
        let unknown = try decode(Pan115QRCodeStatusResponse.self, #"{"state":1,"data":{"status":7}}"#)
        XCTAssertEqual(unknown.data?.value, .unknown(7))
    }

    /// 四件套在 `data.cookie` 里,key 是**大写** `UID` / `CID` / `SEID` / `KID`。
    func testQRCodeLoginDecodesUppercaseCookieKeys() throws {
        let response = try decode(Pan115QRCodeLoginResponse.self, """
        {"state":1,"data":{"cookie":{"UID":"UID-1","CID":"CID-1","SEID":"SEID-1","KID":"KID-1"}}}
        """)
        let credential = try XCTUnwrap(response.data?.credential)
        XCTAssertEqual(credential.uid, "UID-1")
        XCTAssertEqual(credential.cid, "CID-1")
        XCTAssertEqual(credential.seid, "SEID-1")
        XCTAssertEqual(credential.kid, "KID-1")
    }

    /// KID 可缺(老 Cookie 没有),但 UID / CID / SEID 缺一就不算登录成功。
    func testQRCodeLoginWithoutKidStillSucceeds() throws {
        let response = try decode(Pan115QRCodeLoginResponse.self, """
        {"state":1,"data":{"cookie":{"UID":"u","CID":"c","SEID":"s"}}}
        """)
        let credential = try XCTUnwrap(response.data?.credential)
        XCTAssertNil(credential.kid)
        XCTAssertEqual(credential.cookieHeader, "UID=u; CID=c; SEID=s")
    }

    func testQRCodeLoginWithoutSeidIsRejected() throws {
        let response = try decode(Pan115QRCodeLoginResponse.self, """
        {"state":1,"data":{"cookie":{"UID":"u","CID":"c"}}}
        """)
        XCTAssertNil(response.data?.credential)
    }

    // MARK: - 登录态(§2.3)

    func testUserInfoDecodesAccount() throws {
        let response = try decode(Pan115UserInfoResponse.self, """
        {"state":1,"data":{"user_id":42,"user_name":"someone","vip":1}}
        """)
        let account = try XCTUnwrap(response.data?.account)
        XCTAssertEqual(account.userID, "42")
        XCTAssertEqual(account.userName, "someone")
        XCTAssertTrue(account.isVip)
    }

    // MARK: - 目录(§3)

    /// 文件数组在 `data`,而 `cid` / `count` 在外层 —— 这个形状很容易解错。
    func testFileListDecodesEntriesWithAbbreviatedKeys() throws {
        let response = try decode(Pan115FileListResponse.self, """
        {"state":1,"cid":"0","count":2,"data":[
          {"fid":"","cid":"111","n":"电影","s":"0","pc":"","sha":"","te":1767225600},
          {"fid":"2","cid":"0","n":"a.mp4","s":"1024","pc":"PC1","sha":"SHA1","te":1767319445,"iv":"1"}
        ]}
        """)
        XCTAssertEqual(response.count, 2)
        let entries = response.entries
        XCTAssertEqual(entries.count, 2)

        // `fid` 空 = 目录
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[1].name, "a.mp4")
        XCTAssertEqual(entries[1].size, "1024")
        XCTAssertEqual(entries[1].pickCode, "PC1")
        XCTAssertEqual(entries[1].sha1, "SHA1")
        XCTAssertTrue(entries[1].isVideo)
        // `te` 是 unix 秒,不是日期字符串(`p115client tool/attr.py:245-246`)
        XCTAssertEqual(entries[1].modifiedAtSeconds, 1767319445)
        XCTAssertEqual(
            entries[1].file(parentPath: "/影视")?.modifiedAt,
            Date(timeIntervalSince1970: 1767319445))
    }

    /// `te` 缺失时 `modifiedAt` 为 nil,⛔ 不要退回「当前时间」之类的假值。
    func testMissingModifiedTimeStaysNil() throws {
        let response = try decode(Pan115FileListResponse.self, """
        {"state":1,"data":[{"fid":"2","cid":"0","n":"a.mp4"}]}
        """)
        let entry = try XCTUnwrap(response.entries.first)
        XCTAssertNil(entry.modifiedAtSeconds)
        XCTAssertNil(entry.file(parentPath: "/")?.modifiedAt)
    }

    /// 目录条目的 `fid` 是空串,`fsID` 用 `cid` 兜底 —— 否则目录卡没有稳定 id。
    func testDirectoryEntryFallsBackToCIDForNumericID() throws {
        let response = try decode(Pan115FileListResponse.self, """
        {"state":1,"data":[{"fid":"","cid":"999","n":"剧集"}]}
        """)
        let entry = try XCTUnwrap(response.entries.first)
        XCTAssertTrue(entry.isDirectory)
        XCTAssertEqual(entry.numericID, 999)
    }

    /// `isv`(app 端字段名)也要认。
    func testVideoFlagAlsoAcceptsAppKey() throws {
        let response = try decode(Pan115FileListResponse.self, """
        {"state":1,"data":[{"fid":"1","cid":"0","n":"a.mp4","isv":1}]}
        """)
        XCTAssertTrue(try XCTUnwrap(response.entries.first).isVideo)
    }

    /// 缺 `cid` 的条目直接丢:连父目录都不知道,拿不到稳定 id。
    func testEntriesWithoutCIDAreDropped() throws {
        let response = try decode(Pan115FileListResponse.self, """
        {"state":1,"data":[{"fid":"1","n":"a.mp4"},{"fid":"2","cid":"0","n":"b.mp4"}]}
        """)
        XCTAssertEqual(response.entries.map(\.name), ["b.mp4"])
    }

    func testEmptyDataObjectYieldsNoEntries() throws {
        // 错误响应里 `data` 可能是空对象,不能当解码失败
        let response = try decode(Pan115FileListResponse.self, #"{"state":0,"data":{}}"#)
        XCTAssertTrue(response.entries.isEmpty)
    }

    /// 路径换目录 ID 的响应有两种形状:`cid` 与 `id` 都见过。
    func testDirectoryIDAcceptsBothKeys() throws {
        XCTAssertEqual(
            try decode(Pan115DirectoryIDResponse.self, #"{"state":1,"cid":"111"}"#).directoryID, "111")
        XCTAssertEqual(
            try decode(Pan115DirectoryIDResponse.self, #"{"state":1,"id":"222"}"#).directoryID, "222")
        XCTAssertNil(try decode(Pan115DirectoryIDResponse.self, #"{"state":0}"#).directoryID)
    }

    // MARK: - 取直链(§4.1)

    /// `data` 是**密文串**(不是 JSON),要用请求时的同一个 key 解开。
    func testDownloadURLResponseKeepsCiphertext() throws {
        let response = try decode(
            Pan115DownloadURLResponse.self, #"{"state":1,"data":"CIPHERTEXT=="}"#)
        XCTAssertEqual(response.data, "CIPHERTEXT==")
    }

    /// 解开后的形状是 `{fileID: {file_name, file_size, pick_code, url: {url}}}`。
    func testDownloadInfoDecodesNestedURLObject() throws {
        let infos = try decode([String: Pan115DownloadInfo].self, """
        {"42":{"file_name":"a.mp4","file_size":"1024","pick_code":"PC1",
               "url":{"url":"https://cdn.example.com/a.mp4?f=1"}}}
        """)
        let info = try XCTUnwrap(infos["42"])
        XCTAssertEqual(info.fileName, "a.mp4")
        XCTAssertEqual(info.fileSize, 1024)
        XCTAssertEqual(info.pickCode, "PC1")
        XCTAssertEqual(info.url?.host(), "cdn.example.com")
    }

    /// 文件失效时 `url` 是 `false`(`115driver` 专门容错),不能因此让整个解码失败。
    func testDownloadInfoToleratesFalseURL() throws {
        let infos = try decode([String: Pan115DownloadInfo].self, """
        {"42":{"file_name":"a.mp4","pick_code":"PC1","url":false}}
        """)
        XCTAssertNil(try XCTUnwrap(infos["42"]).url)
    }

    // MARK: - 辅助

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
