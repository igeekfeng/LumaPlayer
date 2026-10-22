import XCTest
@testable import LumaPlayer

/// 百度网盘响应解码,字段名以 `docs/BAIDU_PAN_API.md` §4 为准。
/// `media_info` 内层字段名未逐字段核实,断言口径是「取不到就是 nil」。
final class BaiduPanDecodingTests: XCTestCase {

    // MARK: - 列表

    func testDecodesListResponseFromOfficialExampleShape() throws {
        let data = Data(listJSON.utf8)
        let response = try JSONDecoder().decode(BaiduPanListResponse.self, from: data)
        XCTAssertEqual(response.errno, 0)
        XCTAssertEqual(response.list?.count, 2)

        let directory = try XCTUnwrap(response.list?[0].file)
        XCTAssertEqual(directory.fsID, 123456789012345)
        XCTAssertEqual(directory.path, "/apps/LumaPlayer/剧集")
        XCTAssertEqual(directory.name, "剧集")
        XCTAssertTrue(directory.isDirectory)
        XCTAssertEqual(directory.category, 4)

        let image = try XCTUnwrap(response.list?[1].file)
        XCTAssertFalse(image.isDirectory)
        XCTAssertEqual(image.sizeBytes, 233999)
        XCTAssertEqual(image.category, 3)
    }

    /// 目录条目没有 `size` / `md5`,⛔ 不能填 0。
    func testDirectoryEntryLeavesSizeNil() throws {
        let response = try JSONDecoder().decode(BaiduPanListResponse.self, from: Data(listJSON.utf8))
        XCTAssertNil(response.list?[0].file?.sizeBytes)
    }

    /// 缺 `fs_id` / `path` 就没法定位文件 → 整条跳过,不编假的。
    func testEntryWithoutFsIDIsSkipped() throws {
        let json = """
        {"errno":0,"list":[{"path":"/apps/L/x.mp4","server_filename":"x.mp4"}]}
        """
        let response = try JSONDecoder().decode(BaiduPanListResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.list?.first?.file)
    }

    func testNameFallsBackToLastPathComponent() throws {
        let json = """
        {"errno":0,"list":[{"fs_id":1,"path":"/apps/L/a.mp4","isdir":0,"category":1}]}
        """
        let response = try JSONDecoder().decode(BaiduPanListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.list?.first?.file?.name, "a.mp4")
    }

    // MARK: - 元信息

    /// `filemetas` 的真实形状:`errno` + 条目上的 `dlink` / `duration` / `filename`,没有 `media_info`。
    func testDecodesDlinkAndDurationFromFilemetas() throws {
        let json = """
        {"errno":0,"list":[{"fs_id":9,"path":"/apps/L/a.mp4","isdir":0,"filename":"a.mp4",
          "dlink":"https://d.baidupcs.com/file/x?fid=1&sign=abc","duration":7125}]}
        """
        let response = try JSONDecoder().decode(BaiduPanMetaResponse.self, from: Data(json.utf8))
        let entry = try XCTUnwrap(response.list?.first)
        XCTAssertEqual(entry.dlink, "https://d.baidupcs.com/file/x?fid=1&sign=abc")
        XCTAssertEqual(entry.durationSeconds, 7125)
        // `filemetas` 用 `filename`(不是 `server_filename`)
        XCTAssertEqual(entry.file?.name, "a.mp4")
    }

    func testEntryLevelDurationWinsOverMediaInfo() throws {
        let json = """
        {"errno":0,"list":[{"fs_id":9,"path":"/a","duration":100,
          "media_info":{"duration":200}}]}
        """
        let response = try JSONDecoder().decode(BaiduPanMetaResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.list?.first?.durationSeconds, 100)
    }

    /// `filemetas` 给 `errmsg`,列表 / 播放流给 `show_msg`。
    func testMetaFailureMessageReadsErrmsgToo() throws {
        let errmsg = """
        {"errno":-9,"errmsg":"file not found","list":[]}
        """
        let a = try JSONDecoder().decode(BaiduPanMetaResponse.self, from: Data(errmsg.utf8))
        XCTAssertEqual(a.showMessage, "file not found")

        let showMsg = """
        {"errno":-9,"show_msg":"文件不存在","list":[]}
        """
        let b = try JSONDecoder().decode(BaiduPanMetaResponse.self, from: Data(showMsg.utf8))
        XCTAssertEqual(b.showMessage, "文件不存在")
    }

    func testMediaDurationReadsMillisecondsToo() throws {
        let json = """
        {"errno":0,"list":[{"fs_id":9,"path":"/a","media_info":{"duration_ms":7125000}}]}
        """
        let response = try JSONDecoder().decode(BaiduPanMetaResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.list?.first?.mediaInfo?.durationSeconds, 7125)
    }

    /// ⛔ 字段名不对不能让整条解失败(会让整个目录打不开);取不到就是 nil,播放层退回内核读数。
    func testUnknownMediaInfoKeysYieldNilInsteadOfFailure() throws {
        let json = """
        {"errno":0,"list":[{"fs_id":9,"path":"/a","media_info":{"时长":7125,"whatever":"x"}}]}
        """
        let response = try JSONDecoder().decode(BaiduPanMetaResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(response.list?.first)
        XCTAssertNil(response.list?.first?.mediaInfo?.durationSeconds)
    }

    /// 例如不在 `/apps` 下;如实留 nil,由上层报错。
    func testMissingDlinkIsNil() throws {
        let json = """
        {"errno":0,"list":[{"fs_id":9,"path":"/a"}]}
        """
        let response = try JSONDecoder().decode(BaiduPanMetaResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.list?.first?.dlink)
    }

    // MARK: - 归类

    func testKindPrefersServerCategory() {
        let video = BaiduPanFile(
            fsID: 1, path: "/apps/L/a.mkv", name: "a.mkv", sizeBytes: 1,
            isDirectory: false, category: 1, modifiedAt: nil, thumbnailURL: nil)
        XCTAssertEqual(video.kind, .video)
        XCTAssertTrue(video.kind.isPlayable)

        let other = BaiduPanFile(
            fsID: 2, path: "/apps/L/a.txt", name: "a.txt", sizeBytes: 1,
            isDirectory: false, category: 4, modifiedAt: nil, thumbnailURL: nil)
        XCTAssertEqual(other.kind, .other)
        XCTAssertFalse(other.kind.isPlayable)
    }

    /// `BAIDU_PAN_API.md` §5 允许按扩展名判。
    func testKindFallsBackToExtension() {
        let mkv = BaiduPanFile(
            fsID: 1, path: "/apps/L/a.MKV", name: "a.MKV", sizeBytes: 1,
            isDirectory: false, category: nil, modifiedAt: nil, thumbnailURL: nil)
        XCTAssertEqual(mkv.kind, .video)
        XCTAssertEqual(mkv.fileExtension, "mkv", "扩展名要小写")
    }

    // MARK: - 授权

    /// 错误里带响应顶层键名但⛔ 不带值:响应里可能有 token / dlink 签名。
    func testDecodingFailureCarriesTopLevelKeysButNotValues() throws {
        let client = BaiduPanAPIClient()
        let json = #"{"list":[],"request_id":42,"errmsg":"值不该出现在错误里"}"#
        let endpoint = BaiduPanEndpoint.fileList(
            accessToken: "SUPERSECRET", directory: "/", start: 0, limit: 1)

        XCTAssertThrowsError(
            try { let _: BaiduPanMetaResponse = try client.decode(Data(json.utf8), endpoint: endpoint) }()
        ) { error in
            guard case .decoding(let name, let detail) = error as? BaiduPanError else {
                return XCTFail("应当是 decoding 失败:\(error)")
            }
            XCTAssertEqual(name, endpoint.name)
            XCTAssertTrue(detail.contains("缺少字段 errno"), "实际:\(detail)")
            XCTAssertTrue(detail.contains("list"), "顶层键名要带出来:\(detail)")
            XCTAssertFalse(detail.contains("值不该出现在错误里"), "⛔ 不得带响应值:\(detail)")
            XCTAssertFalse(detail.contains("SUPERSECRET"), "⛔ 不得带 token:\(detail)")
        }
    }

    func testTopLevelKeysIsNilForNonObjectJSON() {
        XCTAssertNil(BaiduPanAPIClient.topLevelKeys(in: Data("<html>403</html>".utf8)))
        XCTAssertNil(BaiduPanAPIClient.topLevelKeys(in: Data("[1,2]".utf8)))
        XCTAssertEqual(BaiduPanAPIClient.topLevelKeys(in: Data(#"{"b":1,"a":2}"#.utf8)), ["a", "b"])
    }

    func testDecodesDeviceCode() throws {
        let json = """
        {"device_code":"dc","user_code":"8drp69hk",
         "verification_url":"https://openapi.baidu.com/device",
         "qrcode_url":"https://openapi.baidu.com/device/qrcode/abc/8drp69hk",
         "expires_in":300,"interval":5}
        """
        let response = try JSONDecoder().decode(BaiduPanDeviceCodeResponse.self, from: Data(json.utf8))
        let code = response.deviceCodeValue
        XCTAssertEqual(code.deviceCode, "dc")
        XCTAssertEqual(code.userCode, "8drp69hk")
        XCTAssertEqual(code.expiresIn, 300)
        XCTAssertEqual(code.interval, 5)
        // ⛔ 二维码内容按官方的拼接规则,不是 qrcode_url 那张图片地址
        XCTAssertEqual(code.qrCodeContent, "https://openapi.baidu.com/device?display=mobile&code=8drp69hk")
        XCTAssertNotNil(code.qrCodeImageURL)
    }

    /// 官方:轮询间隔不能低于 5 秒。
    func testIntervalIsClampedToFiveSeconds() throws {
        let json = """
        {"device_code":"dc","user_code":"u","expires_in":300,"interval":1}
        """
        let response = try JSONDecoder().decode(BaiduPanDeviceCodeResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.deviceCodeValue.interval, 5)
    }

    func testDecodesTokenResponse() throws {
        let json = """
        {"expires_in":2592000,"refresh_token":"RT","access_token":"AT","scope":"basic netdisk"}
        """
        let response = try JSONDecoder().decode(BaiduPanTokenResponse.self, from: Data(json.utf8))
        // 秒 → 绝对时间,否则重启后「还剩多久」无从判断
        let bundle = try XCTUnwrap(response.bundle(now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(bundle.accessToken, "AT")
        XCTAssertEqual(bundle.refreshToken, "RT")
        XCTAssertEqual(bundle.expiresAt, Date(timeIntervalSince1970: 2592000))
        XCTAssertFalse(bundle.needsRefresh(now: Date(timeIntervalSince1970: 1000)))
        // 提前 5 分钟就该刷了
        XCTAssertTrue(bundle.needsRefresh(now: Date(timeIntervalSince1970: 2592000 - 60)))
    }

    /// 刷新成功那一刻旧 refresh_token 已失效(`BAIDU_PAN_API.md` §6),⛔ 不沿用旧的。
    func testTokenWithoutRefreshTokenIsRejected() throws {
        let json = """
        {"expires_in":2592000,"access_token":"AT"}
        """
        let response = try JSONDecoder().decode(BaiduPanTokenResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.bundle())
    }

    func testDecodesOAuthError() throws {
        let json = """
        {"error":"invalid_grant","error_description":"授权已失效"}
        """
        let response = try JSONDecoder().decode(BaiduPanOAuthErrorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.error, "invalid_grant")
        // 官方没写「用户还没确认」返回什么,所以只认肯定致命的码,其余继续等(见 `isFatalOAuthCode`)
        XCTAssertFalse(BaiduPanError.isFatalOAuthCode("invalid_grant"))
        XCTAssertFalse(BaiduPanError.isFatalOAuthCode("authorization_pending"))
        XCTAssertTrue(BaiduPanError.isFatalOAuthCode("invalid_client"))
        XCTAssertTrue(BaiduPanError.isFatalOAuthCode("access_denied"))
    }

    /// `errno=133`(非会员要看广告):读出 `adToken` 带回重试。
    func testDecodesAdEnvelope() throws {
        let json = """
        {"errno":133,"request_id":123,"adTime":15,"adToken":"TOK","ltime":15}
        """
        let envelope = try JSONDecoder().decode(BaiduPanErrnoEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.errno, 133)
        XCTAssertEqual(envelope.adToken, "TOK")
    }

    // MARK: - 删除结果(`docs/BAIDU_PAN_API.md` §2.4)

    /// 顶层 `errno == 0` 只表示受理,单条失败在 `info[].errno`;只看顶层会把「没删掉」吞成成功。
    func testFileManagerResultKeepsPerItemErrno() throws {
        let json = """
        {"errno":0,"info":[{"errno":-9,"path":"/apps/LumaPlayer/a.mkv"}],
         "request_id":9131857965670515801}
        """
        let response = try JSONDecoder().decode(
            BaiduPanFileManagerResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.errno, 0, "顶层只表示受理")
        let entry = try XCTUnwrap(response.info?.first)
        XCTAssertEqual(entry.errno, -9, "逐条结果要留着,这才是删没删成的判据")
        XCTAssertEqual(entry.path, "/apps/LumaPlayer/a.mkv")
    }

    /// 异步(`async≠0`)只回 `taskid`、没有 `info`,说不清删没删成。
    func testAsyncFileManagerResponseHasNoPerItemResult() throws {
        let json = """
        {"errno":0,"info":[],"request_id":9132303301733449639,"taskid":569942193355668}
        """
        let response = try JSONDecoder().decode(
            BaiduPanFileManagerResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.info?.isEmpty, true)
        XCTAssertEqual(response.taskID, 569942193355668)
    }

    // MARK: - 错误文案

    func testErrnoMessagesAreExplainable() {
        XCTAssertTrue(BaiduPanErrno.userMessage(errno: 31347, serverMessage: nil)
            .contains("太长"), "要有可行动的原因,不能只报数字")
        XCTAssertTrue(BaiduPanErrno.userMessage(errno: -7, serverMessage: nil)
            .contains("/apps"))
        // 表外的码原样带出 errno,⛔ 不编一个「大概是权限问题」
        XCTAssertTrue(BaiduPanErrno.userMessage(errno: 99999, serverMessage: nil)
            .contains("99999"))
    }

    // MARK: - 目录地址

    /// ⛔ 不用 `hasPrefix(root)`:会把 `/apps/LumaPlayerXX` 也算进 `/apps/LumaPlayer`。
    func testLibraryRootBoundaryUsesSlashSuffix() {
        XCTAssertTrue(BaiduPanPath.isInside("/apps/LumaPlayer", applicationRoot: "/apps/LumaPlayer"))
        XCTAssertTrue(BaiduPanPath.isInside("/apps/LumaPlayer/sub", applicationRoot: "/apps/LumaPlayer"))
        XCTAssertFalse(BaiduPanPath.isInside("/apps/LumaPlayerXX", applicationRoot: "/apps/LumaPlayer"))
        XCTAssertFalse(BaiduPanPath.isInside("", applicationRoot: "/apps/LumaPlayer"))
    }

    private let listJSON = """
    {
      "errno": 0,
      "guid_info": "",
      "request_id": 1234567890,
      "list": [
        {
          "server_filename": "剧集",
          "privacy": 0,
          "category": 4,
          "unlist": 0,
          "fs_id": 123456789012345,
          "dir_empty": 1,
          "server_atime": 0,
          "isdir": 1,
          "path": "/apps/LumaPlayer/剧集",
          "size": 0,
          "server_ctime": 1596078019,
          "server_mtime": 1596078019,
          "share": 0,
          "empty": 0,
          "oper_id": 1234567890
        },
        {
          "server_filename": "poster.jpg",
          "privacy": 0,
          "category": 3,
          "unlist": 0,
          "fs_id": 123456789012346,
          "isdir": 0,
          "path": "/apps/LumaPlayer/poster.jpg",
          "size": 233999,
          "md5": "HASH",
          "share": 0,
          "thumbs": { "url1": "u1", "url2": "u2", "url3": "u3" }
        }
      ],
      "guid": 0
    }
    """
}
