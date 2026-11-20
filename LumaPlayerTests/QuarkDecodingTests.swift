import XCTest
@testable import LumaPlayer

/// 夸克的线格式解码与信封判定(`docs/QUARK_API.md` §3 - §5)。
///
/// 样本全是 2026-11-20 无凭据实测拿到的响应原话形状,不是编的。
final class QuarkDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - 信封

    /// 成功:`status: 0` + `errno: 0`
    func testEnvelopeSuccess() throws {
        let envelope: QuarkEnvelope = try decode(#"{"status":0,"errno":0,"req_id":"x"}"#)
        XCTAssertTrue(envelope.isSuccess)
    }

    /// `errno` 缺失按 0 处理(参考 `quarkTv.mjs:96`)。
    func testEnvelopeTreatsMissingErrnoAsZero() throws {
        let envelope: QuarkEnvelope = try decode(#"{"status":0,"req_id":"x"}"#)
        XCTAssertTrue(envelope.isSuccess)
        XCTAssertEqual(envelope.effectiveErrno, 0)
    }

    /// 实测:`11001 Access Token无效` 是**要刷新**的那一档。
    func testAccessTokenInvalidIsSeparateFromSignatureInvalid() throws {
        let envelope: QuarkEnvelope = try decode(
            #"{"status":-1,"errno":11001,"error_info":"Access Token无效","req_id":"x"}"#)
        XCTAssertFalse(envelope.isSuccess)
        XCTAssertEqual(envelope.effectiveErrno, QuarkCode.tokenInvalid)
        XCTAssertEqual(envelope.errorMessage, "Access Token无效")
    }

    /// ⚠️ 实测回归:`10001` 是「签名验证失败 / 公参缺失」,**不是** token 过期。
    /// 文档原本按 OpenList 的注释推断成「token 过期」,照那个写会把每次签名错误都当成要刷新。
    func testSignatureFailureIsNotTreatedAsTokenExpiry() throws {
        let envelope: QuarkEnvelope = try decode(
            #"{"status":-1,"errno":10001,"error_info":"签名验证失败，禁止访问","req_id":"x"}"#)
        XCTAssertEqual(envelope.effectiveErrno, QuarkCode.signatureInvalid)
        XCTAssertNotEqual(envelope.effectiveErrno, QuarkCode.tokenInvalid)
    }

    // MARK: - 扫码(§4)

    /// 第 1 步:`qr_data` 是 base64 图片本身(实测前缀 `iVBORw0KGgo` = PNG)
    func testAuthorizeResponseCarriesQRImageAndQueryToken() throws {
        let response: QuarkAuthorizeResponse = try decode(
            #"{"status":0,"req_id":"r","qr_data":"iVBORw0KGgoAAAANSUhEUg","query_token":"sta336333f40azrpiv8xnftwwsebgw36"}"#)
        let session = try XCTUnwrap(response.session)
        XCTAssertEqual(session.queryToken, "sta336333f40azrpiv8xnftwwsebgw36")
        XCTAssertEqual(session.imageBase64, "iVBORw0KGgoAAAANSUhEUg")
    }

    /// 缺 `query_token` 时⛔ 不能造一个空串会话:那会让轮询一直问一个空 query。
    func testAuthorizeResponseWithoutQueryTokenHasNoSession() throws {
        let response: QuarkAuthorizeResponse = try decode(
            #"{"status":0,"req_id":"r","qr_data":"abc"}"#)
        XCTAssertNil(response.session)
    }

    /// 第 3 步的「还没确认」实测形状:HTTP 400 + `errno 11003`。
    func testPendingCodeResponseKeepsErrnoForCallerToWait() throws {
        let response: QuarkCodeResponse = try decode(
            #"{"status":-1,"errno":11003,"error_info":"用户未确认授权","req_id":"x"}"#)
        XCTAssertFalse(response.envelope.isSuccess)
        XCTAssertEqual(response.envelope.effectiveErrno, QuarkCode.authorizationPending)
        XCTAssertNil(response.code)
    }

    /// 第 4 步:外层 `code: 200` 只表示受理,内层 `data.errno` 才是结论(实测 `11004 授权码Code无效`)。
    func testTokenExchangeFailureIsInsideData() throws {
        let response: QuarkTokenExchangeResponse = try decode(
            #"{"code":200,"message":"OK","data":{"status":-1,"errno":11004,"error_info":"授权码Code无效","req_id":"r","access_token":"","refresh_token":"","expires_in":0,"scope":""}}"#)
        XCTAssertEqual(response.code, 200)
        let payload = try XCTUnwrap(response.data)
        XCTAssertFalse(payload.envelope.isSuccess)
        XCTAssertEqual(payload.envelope.effectiveErrno, QuarkCode.authorizationCodeInvalid)
        XCTAssertNil(payload.tokens)
    }

    /// 成功时两枚令牌都要在;`refresh_token` 空就算失败(§4)。
    func testTokenExchangeSuccessNeedsBothTokens() throws {
        let json = #"{"code":200,"message":"OK","data":{"status":0,"errno":0,"access_token":"a","refresh_token":"r","expires_in":3600,"scope":"netdisk"}}"#
        let response: QuarkTokenExchangeResponse = try decode(json)
        let tokens = try XCTUnwrap(response.data?.tokens)
        XCTAssertEqual(tokens.access, "a")
        XCTAssertEqual(tokens.refresh, "r")

        let missingRefresh = #"{"code":200,"message":"OK","data":{"status":0,"errno":0,"access_token":"a","refresh_token":""}}"#
        let failed: QuarkTokenExchangeResponse = try decode(missingRefresh)
        XCTAssertNil(failed.data?.tokens)
    }

    /// 外层非 200:第三方服务自己拒了请求(`req_id` / `app_ver` 必填,实测)。
    func testTokenExchangeOuterFailureKeepsMessage() throws {
        let response: QuarkTokenExchangeResponse = try decode(
            #"{"code":400,"message":"req_id为必填字段; app_ver为必填字段"}"#)
        XCTAssertEqual(response.code, 400)
        XCTAssertNil(response.data)
        XCTAssertEqual(response.message, "req_id为必填字段; app_ver为必填字段")
    }

    // MARK: - 目录(§5)

    /// 条目字段:时间戳是**毫秒**(§5.1),`size` 可能是字符串。
    func testFileListDecodesMillisecondTimestamps() throws {
        let json = #"""
        {"status":0,"errno":0,"req_id":"r","data":{"total_count":1,"files":[
          {"fid":"a1b2c3","parent_fid":"0","filename":"电影.mp4","size":1048576,
           "isdir":0,"category":1,"duration":7200,
           "created_at":1700000000000,"updated_at":1700000005000}
        ]}}
        """#
        let response: QuarkFileListResponse = try decode(json)
        XCTAssertEqual(response.totalCount, 1)
        let entry = try XCTUnwrap(response.files.first)
        XCTAssertEqual(entry.fid, "a1b2c3")
        XCTAssertEqual(entry.name, "电影.mp4")
        XCTAssertEqual(entry.sizeBytes, 1_048_576)
        XCTAssertFalse(entry.isDirectory)
        XCTAssertTrue(entry.isVideo)
        XCTAssertEqual(entry.durationSeconds, 7200)
        // 毫秒 → 秒:2023-11-14T22:13:20Z
        XCTAssertEqual(entry.modifiedAt?.timeIntervalSince1970 ?? 0, 1_700_000_005, accuracy: 0.001)
        XCTAssertEqual(entry.createdAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
    }

    /// 缺 `fid` / `filename` 的条目直接丢:没有它在项目里既定位不了也显示不了。
    func testFileListDropsEntriesWithoutIdentity() throws {
        let json = #"""
        {"status":0,"errno":0,"data":{"total_count":3,"files":[
          {"filename":"没有 fid.mp4","isdir":0},
          {"fid":"x","isdir":1},
          {"fid":"y","filename":"有.mp4","isdir":0,"category":1}
        ]}}
        """#
        let response: QuarkFileListResponse = try decode(json)
        XCTAssertEqual(response.files.count, 1)
        XCTAssertEqual(response.files.first?.fid, "y")
    }

    /// 目录条目:`isdir: 1`,大小常是 0。
    func testDirectoryEntry() throws {
        let json = #"""
        {"status":0,"errno":0,"data":{"total_count":1,"files":[
          {"fid":"d1","parent_fid":"0","filename":"影视","size":0,"isdir":1,"category":0}
        ]}}
        """#
        let response: QuarkFileListResponse = try decode(json)
        let entry = try XCTUnwrap(response.files.first)
        XCTAssertTrue(entry.isDirectory)
        XCTAssertFalse(entry.isVideo)
        XCTAssertNil(entry.modifiedAt)
    }

    // MARK: - 取直链(§6.1)

    func testDownloadResponse() throws {
        let json = #"""
        {"status":0,"errno":0,"data":{"fid":"f1","file_name":"a.mkv","size":2048,
         "download_url":"https://cdn.quark.cn/x?a=1&sign=abc%2B"}}
        """#
        let response: QuarkDownloadResponse = try decode(json)
        XCTAssertEqual(response.fid, "f1")
        XCTAssertEqual(response.size, 2048)
        let raw = try XCTUnwrap(response.downloadURL)
        // ⚠️ 地址原样采用,⛔ 不做 URLComponents 往返
        XCTAssertEqual(URL(string: raw)?.absoluteString, raw)
    }

    // MARK: - 登录态(§7)

    func testUserInfo() throws {
        let json = #"{"status":0,"errno":0,"data":{"nickname":"测试用户","vip":1}}"#
        let response: QuarkUserInfoResponse = try decode(json)
        XCTAssertEqual(response.account, QuarkAccount(nickname: "测试用户", isVip: true))
    }

    /// 什么都不给时不编账号信息:⛔ 不假装是会员。
    func testUserInfoWithoutPayload() throws {
        let response: QuarkUserInfoResponse = try decode(#"{"status":0,"errno":0}"#)
        XCTAssertEqual(response.account, QuarkAccount(nickname: nil, isVip: false))
    }
}
