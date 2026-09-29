import XCTest
@testable import LumaPlayer

/// fixture 解码:字段缺失不崩、必填缺失报错
/// (API_CONTRACT.md 8.1 的可选性原则与必填表;ARCHITECTURE.md 10.1)。
///
/// `public_info.json` 是**真实响应脱敏**后的 fixture(4.7.11.0,2026-09-22,
/// 见 CLAUDE.md「真实服务器使用纪律」);
/// 其余带 `_synthetic` 后缀的仍是构造数据,未经真实服务器验证(API_CONTRACT.md 9.4)。
final class EmbyFixtureDecodingTests: XCTestCase {
    private let decoder = ResponseDecoder()

    func testPublicServerInfoDecodes() throws {
        let info = try decode(EmbyServerInfo.self, "public_info.json", endpoint: .publicSystemInfo)
        XCTAssertEqual(info.id, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(info.serverName, "emby.test")
        XCTAssertEqual(info.version, "4.7.11.0")
    }

    func testRealResponseWithUnknownFieldsDecodes() throws {
        // 真实响应里有 LocalAddresses / RemoteAddresses / IsCuveeServer 这些
        // 我们不需要的字段:未知字段必须被忽略,不得导致解码失败(8.1)
        let info = try decode(EmbyServerInfo.self, "public_info.json", endpoint: .publicSystemInfo)
        XCTAssertNotNil(info.id)
        XCTAssertEqual(info.version, "4.7.11.0")
    }

    func testPublicServerInfoWithMissingFieldsDecodesToNil() throws {
        // 端点字段全缺:不崩、不填假默认值(8.1)
        let info = try decode(
            EmbyServerInfo.self,
            "public_info_missing_fields_synthetic.json",
            endpoint: .publicSystemInfo
        )
        XCTAssertNil(info.id)
        XCTAssertNil(info.serverName)
        XCTAssertNil(info.version)
    }

    func testAuthenticationResultDecodes() throws {
        let result = try decode(
            AuthenticationResult.self,
            "authenticate_success_synthetic.json",
            endpoint: .authenticateByName(username: "alice", password: "secret")
        )
        XCTAssertEqual(result.accessToken, "FAKE_TOKEN_0123456789")
        XCTAssertEqual(result.user.id, "00000000-0000-0000-0000-000000000003")
        XCTAssertEqual(result.user.name, "testuser")
        XCTAssertEqual(result.serverID, "00000000-0000-0000-0000-000000000002")
    }

    func testMissingAccessTokenIsDecodingError() throws {
        // AccessToken 在 8.1 的必填表里:缺失即视为响应损坏
        do {
            _ = try decode(
                AuthenticationResult.self,
                "authenticate_missing_token_synthetic.json",
                endpoint: .authenticateByName(username: "alice", password: "secret")
            )
            XCTFail("缺少 AccessToken 应抛 decoding")
        } catch let error as EmbyAPIError {
            guard case .decoding(_, let endpointName) = error else {
                return XCTFail("期望 .decoding,实际 \(error)")
            }
            XCTAssertEqual(endpointName, "Users/AuthenticateByName")
        }
    }

    func testViewsResponseDecodesNullCollectionType() throws {
        let response = try decode(
            EmbyItemsResponse<EmbyView>.self,
            "user_views_mixed_synthetic.json",
            endpoint: .userViews(userID: "USER-1")
        )
        XCTAssertEqual(response.items.count, 3)
        XCTAssertEqual(response.totalRecordCount, 3)
        XCTAssertEqual(response.items.map(\.collectionType), ["movies", "tvshows", nil])
    }

    func testViewDecodesPrimaryImageTagForCover() throws {
        // 媒体库封面:ImageTags["Primary"] 优先,缺失回退 PrimaryImageTag,都没有就不请求(3.3 / Q13)
        let json = Data(#"""
        {"Items":[
          {"Id":"V1","Name":"电影","ImageTags":{"Primary":"tag-a"}},
          {"Id":"V2","Name":"剧集","PrimaryImageTag":"tag-b"},
          {"Id":"V3","Name":"混合"}
        ]}
        """#.utf8)
        let response = try decoder.decode(
            EmbyItemsResponse<EmbyView>.self,
            from: json,
            endpointName: "Users/{UserId}/Views"
        )
        XCTAssertEqual(response.items.map(\.primaryImageTagValue), ["tag-a", "tag-b", nil])
    }

    func testViewWithoutIdIsDecodingError() throws {
        // BaseItem 的 Id 必填(8.1)
        let json = Data(#"{"Items":[{"Name":"没有 Id 的库"}]}"#.utf8)
        XCTAssertThrowsError(
            try decoder.decode(
                EmbyItemsResponse<EmbyView>.self,
                from: json,
                endpointName: "Users/{UserId}/Views"
            )
        )
    }

    // MARK: - 辅助

    private func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        _ fixture: String,
        endpoint: EmbyEndpoint
    ) throws -> T {
        try decoder.decode(type, from: try FixtureLoader.data(fixture), endpointName: endpoint.name)
    }
}
