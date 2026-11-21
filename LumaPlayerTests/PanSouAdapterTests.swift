import Foundation
import Testing

@testable import LumaPlayer

/// PanSou 适配器(`PanSouAdapter`):请求形状与响应归一化。
///
/// 用 `MockEmbyURLProtocol` 拦网络:它的 key 是 scheme + host + path,
/// 所以这里把源地址写成 `https://pansou.test`,请求就会落在预设的 stub 上。
// ⚠️ `.serialized`:`MockEmbyURLProtocol` 的 stub 是进程级静态状态,
// 并行跑会让一个用例的 `reset()` 清掉另一个用例刚设的响应(表现是「不是合法 JSON」)。
@Suite("PanSou 适配器", .serialized)
struct PanSouAdapterTests {

    private static func source(_ baseURL: String = "https://pansou.test") -> ResourceSource {
        ResourceSource(
            id: "pansou-test",
            displayName: "测试 PanSou",
            kind: .panSou,
            baseURL: baseURL)
    }

    private static func adapter() -> PanSouAdapter {
        PanSouAdapter(session: MockEmbyURLProtocol.makeSession())
    }

    private static let envelopeWithTwoResults = """
    {
      "code": 0,
      "message": "success",
      "data": {
        "total": 2,
        "results": [
          {
            "message_id": "m1",
            "unique_id": "pansou-m1",
            "datetime": "2026-11-20T10:00:00+08:00",
            "title": "仙逆 全集 4K",
            "content": "更新至第 120 集",
            "links": [
              {"type": "baidu", "url": "https://pan.baidu.com/s/1AbCd", "password": "abcd"},
              {"type": "quark", "url": "https://pan.quark.cn/s/xyz", "password": ""}
            ]
          },
          {
            "message_id": "m2",
            "title": "只有文本没有链接的条目",
            "links": []
          }
        ]
      }
    }
    """

    @Test("归一化:标题、时间、多个链接、空密码变 nil")
    func normalizesResults() async throws {
        MockEmbyURLProtocol.reset()
        MockEmbyURLProtocol.stub(
            .json(Self.envelopeWithTwoResults), host: "pansou.test", path: "/api/search")

        let resources = try await Self.adapter().search(keyword: "仙逆", source: Self.source())

        // ⛔ 没有链接的条目不是资源,不能进列表
        #expect(resources.count == 1)
        let resource = try #require(resources.first)
        #expect(resource.title == "仙逆 全集 4K")
        #expect(resource.id == "pansou-m1")
        #expect(resource.links.count == 2)
        #expect(resource.links[0].cloudType == .baidu)
        #expect(resource.links[0].password == "abcd")
        // PanSou 用空串表示「不要码」,模型层统一成 nil
        #expect(resource.links[1].password == nil)
        #expect(resource.publishedAt != nil)
        #expect(resource.primaryCloudType == .baidu)
    }

    @Test("请求体带 kw / res=results / src=plugin")
    func sendsExpectedBody() async throws {
        MockEmbyURLProtocol.reset()
        MockEmbyURLProtocol.stub(
            .json(Self.envelopeWithTwoResults), host: "pansou.test", path: "/api/search")

        _ = try await Self.adapter().search(keyword: "仙逆", source: Self.source())

        let request = try #require(
            MockEmbyURLProtocol.lastRequest(matchingPathSuffix: "/api/search"))
        #expect(request.method == "POST")
        let body = try #require(request.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["kw"] as? String == "仙逆")
        // 只取 results:merged_by_type 里没有标题
        #expect(json["res"] as? String == "results")
        #expect(json["src"] as? String == "plugin")
    }

    @Test("业务错误码折成 sourceFailed 而不是空结果")
    func businessErrorCode() async {
        MockEmbyURLProtocol.reset()
        MockEmbyURLProtocol.stub(
            .json(#"{"code":500,"message":"搜索失败"}"#),
            host: "pansou.test", path: "/api/search")

        do {
            _ = try await Self.adapter().search(keyword: "x", source: Self.source())
            Issue.record("应抛错")
        } catch let error as PanResourceSearchError {
            guard case .sourceFailed(_, _, let message) = error else {
                Issue.record("应为 sourceFailed,实际 \(error)")
                return
            }
            #expect(message == "搜索失败")
        } catch {
            Issue.record("应为 PanResourceSearchError,实际 \(error)")
        }
    }

    @Test("200 但返回 HTML(反爬页)要说清「不是 JSON」")
    func htmlResponse() async {
        MockEmbyURLProtocol.reset()
        MockEmbyURLProtocol.stub(
            .json("<html>Just a moment...</html>"),
            host: "pansou.test", path: "/api/search")

        do {
            _ = try await Self.adapter().search(keyword: "x", source: Self.source())
            Issue.record("应抛错")
        } catch let error as PanResourceSearchError {
            guard case .decoding(_, let detail) = error else {
                Issue.record("应为 decoding,实际 \(error)")
                return
            }
            #expect(detail.contains("JSON"))
        } catch {
            Issue.record("应为 PanResourceSearchError,实际 \(error)")
        }
    }

    @Test("空关键词不发请求")
    func emptyKeyword() async {
        MockEmbyURLProtocol.reset()
        do {
            _ = try await Self.adapter().search(keyword: "   ", source: Self.source())
            Issue.record("应抛错")
        } catch let error as PanResourceSearchError {
            #expect(error == .emptyKeyword)
        } catch {
            Issue.record("应为 PanResourceSearchError,实际 \(error)")
        }
        #expect(MockEmbyURLProtocol.recordedRequests().isEmpty)
    }

    @Test("地址拼接:带不带尾斜杠、带不带子路径都能拼对")
    func searchURLBuilding() {
        #expect(
            PanSouAdapter.searchURL(baseURL: "https://a.test")?.absoluteString
                == "https://a.test/api/search")
        #expect(
            PanSouAdapter.searchURL(baseURL: "https://a.test/")?.absoluteString
                == "https://a.test/api/search")
        #expect(
            PanSouAdapter.searchURL(baseURL: "https://a.test/pansou/")?.absoluteString
                == "https://a.test/pansou/api/search")
        #expect(PanSouAdapter.searchURL(baseURL: "  ") == nil)
    }

    @Test("时间解析:RFC3339 带/不带毫秒")
    func dateParsing() throws {
        #expect(PanSouAdapter.parseDate("2026-11-20T10:00:00+08:00") != nil)
        #expect(PanSouAdapter.parseDate("2026-11-20T10:00:00.123Z") != nil)
        #expect(PanSouAdapter.parseDate("不是时间") == nil)
    }
}

/// 聚合编排(`PanResourceSearchService`):去重与排序。
@Suite("资源聚合")
struct PanResourceSearchServiceTests {

    private static func resource(
        title: String,
        url: String,
        sourceID: String = "a",
        summary: String? = nil,
        date: Date? = nil,
        extraLinks: Int = 0
    ) -> PanResource {
        var links = [PanResourceLink(url: url, cloudType: .baidu, password: nil)]
        for index in 0..<extraLinks {
            links.append(
                PanResourceLink(
                    url: url + "/extra\(index)", cloudType: .quark, password: nil))
        }
        return PanResource(
            id: "\(sourceID)-\(title)",
            title: title,
            summary: summary,
            publishedAt: date,
            links: links,
            sourceID: sourceID,
            rank: nil)
    }

    @Test("同一分享地址只留一条,留信息更全的")
    func deduplicatesByShareURL() {
        let sparse = Self.resource(title: "仙逆", url: "https://pan.baidu.com/s/1AbCd")
        let rich = Self.resource(
            title: "仙逆 全集 4K 120集", url: "https://pan.baidu.com/s/1AbCd?pwd=x",
            summary: "更新至 120 集", date: Date())

        let merged = PanResourceSearchService.merge([sparse, rich])

        #expect(merged.count == 1)
        // 更全的那条胜出(链接多 / 有摘要 / 有时间 / 标题长)
        #expect(merged[0].title == "仙逆 全集 4K 120集")
    }

    @Test("不同网盘的同一部剧是两条资源")
    func differentCloudTypesStaySeparate() {
        let baidu = Self.resource(title: "仙逆", url: "https://pan.baidu.com/s/1AbCd")
        let quark = Self.resource(title: "仙逆", url: "https://pan.quark.cn/s/xyz")

        let merged = PanResourceSearchService.merge([baidu, quark])

        #expect(merged.count == 2)
    }

    @Test("按时间倒序,没有时间的排后面")
    func ordersByDate() {
        let old = Self.resource(
            title: "旧", url: "https://pan.baidu.com/s/1old",
            date: Date(timeIntervalSince1970: 1000))
        let new = Self.resource(
            title: "新", url: "https://pan.baidu.com/s/1new",
            date: Date(timeIntervalSince1970: 2000))
        let undated = Self.resource(title: "无时间", url: "https://pan.baidu.com/s/1none")

        let merged = PanResourceSearchService.merge([old, undated, new])

        #expect(merged.map(\.title) == ["新", "旧", "无时间"])
    }

    @Test("归一化分享地址:去查询串与尾斜杠")
    func normalizesShareURL() {
        #expect(
            PanResource.normalizeShareURL("https://pan.baidu.com/s/1AbCd/?pwd=abcd")
                == "pan.baidu.com/s/1AbCd")
        #expect(
            PanResource.normalizeShareURL("https://PAN.BAIDU.COM/s/1AbCd")
                == "pan.baidu.com/s/1AbCd")
    }

    @Test("按网盘类型筛选:一条资源可出现在多个分组里")
    func filtersByCloudType() {
        let both = PanResource(
            id: "both",
            title: "两个网盘都有",
            summary: nil,
            publishedAt: nil,
            links: [
                PanResourceLink(url: "https://pan.baidu.com/s/1a", cloudType: .baidu, password: nil),
                PanResourceLink(url: "https://pan.quark.cn/s/b", cloudType: .quark, password: nil),
            ],
            sourceID: "a",
            rank: nil)
        let onlyBaidu = Self.resource(title: "只有百度", url: "https://pan.baidu.com/s/1c")

        let resources = [both, onlyBaidu]
        #expect(PanResourceSearchService.filter(resources, cloudType: .baidu).count == 2)
        #expect(PanResourceSearchService.filter(resources, cloudType: .quark).count == 1)
        #expect(PanResourceSearchService.filter(resources, cloudType: nil).count == 2)

        let types = PanResourceSearchService.availableCloudTypes(in: resources)
        #expect(types.contains(.baidu))
        #expect(types.contains(.quark))
    }
}
