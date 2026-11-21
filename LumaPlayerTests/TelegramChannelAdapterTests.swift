import Foundation
import Testing

@testable import LumaPlayer

/// Telegram 频道适配器:频道名解析、HTML 切块、链接抽取、降噪。
///
/// 网络层用 `MockEmbyURLProtocol` 拦(`.serialized`:它的 stub 是进程级静态状态)。
@Suite("Telegram 频道适配器", .serialized)
struct TelegramChannelAdapterTests {

    private static func source(_ channel: String = "tgsearchers7") -> ResourceSource {
        ResourceSource(
            id: "tg-test",
            displayName: "测试频道",
            kind: .telegramChannel,
            baseURL: channel)
    }

    private static func adapter() -> TelegramChannelAdapter {
        TelegramChannelAdapter(session: MockEmbyURLProtocol.makeSession())
    }

    /// 照 `t.me/s/<频道>?q=` 的真实结构裁的最小页面:两条带链接、一条纯文本。
    private static let pageHTML = """
    <html><body>
    <div class="tgme_widget_message_wrap js-widget_message_wrap">
      <div class="tgme_widget_message js-widget_message" data-post="tgsearchers7/104198">
        <time datetime="2026-10-04T10:45:27+00:00"></time>
        <div class="tgme_widget_message_text js-message_text" dir="auto">
          名称：<mark class="highlight">仙逆</mark>（2025）4K 更新至161集<br/><br/>
          描述：改编自耳根同名小说<br/><br/>
          百度：<a href="https://pan.baidu.com/s/1ZbS21-UbLFt3Q7NEQUx7CA?pwd=sbez" target="_blank">https://pan.baidu.com/s/1ZbS21-UbLFt3Q7NEQUx7CA?pwd=sbez</a>
          <br/><br/>标签：<a href="?q=%23国漫">#国漫</a>
        </div>
      </div>
    </div>
    <div class="tgme_widget_message_wrap js-widget_message_wrap">
      <div class="tgme_widget_message js-widget_message" data-post="tgsearchers7/104201">
        <time datetime="2026-10-04T10:45:32+00:00"></time>
        <div class="tgme_widget_message_text js-message_text" dir="auto">
          名称：仙逆年番 4K 更新至161集<br/><br/>
          夸克：<a href="https://pan.quark.cn/s/73c92feec46b">https://pan.quark.cn/s/73c92feec46b</a>
          <br/>提取码: 8x2k
        </div>
      </div>
    </div>
    <div class="tgme_widget_message_wrap js-widget_message_wrap">
      <div class="tgme_widget_message js-widget_message" data-post="tgsearchers7/104205">
        <div class="tgme_widget_message_text js-message_text" dir="auto">
          名称：只有文字没有链接的更新公告
        </div>
      </div>
    </div>
    <div class="tgme_widget_messages_more_wrap">
      <a href="/s/tgsearchers7?q=%E4%BB%99%E9%80%86&amp;before=104198" data-before="104198"></a>
    </div>
    </body></html>
    """

    @Test("频道名:裸名 / @名 / t.me 链接 / /s/ 链接 都认")
    func parsesChannelNames() {
        #expect(TelegramChannelAdapter.channelName(from: "tgsearchers7") == "tgsearchers7")
        #expect(TelegramChannelAdapter.channelName(from: "@Quark_Movies") == "Quark_Movies")
        #expect(TelegramChannelAdapter.channelName(from: "https://t.me/ucquark") == "ucquark")
        #expect(TelegramChannelAdapter.channelName(from: "https://t.me/s/guoman4K?q=x") == "guoman4K")
    }

    @Test("频道名:太短 / 带非法字符 / 空串 一律无效,⛔ 不猜")
    func rejectsInvalidChannelNames() {
        #expect(TelegramChannelAdapter.channelName(from: "") == nil)
        #expect(TelegramChannelAdapter.channelName(from: "ab") == nil)
        #expect(TelegramChannelAdapter.channelName(from: "bad name") == nil)
        #expect(TelegramChannelAdapter.channelName(from: "https://example.com/foo") == nil)
    }

    @Test("搜索地址带 q 与 before")
    func buildsSearchURL() throws {
        let url = try #require(
            TelegramChannelAdapter.searchURL(channel: "tgsearchers7", keyword: "仙逆", before: "104198"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "t.me")
        #expect(components.path == "/s/tgsearchers7")
        #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "仙逆")
        #expect(components.queryItems?.first(where: { $0.name == "before" })?.value == "104198")
    }

    @Test("解析:标题取「名称」、时间、多链接、提取码、无链接条目丢弃")
    func parsesPage() throws {
        let resources = TelegramChannelAdapter.parseMessages(
            Self.pageHTML, channel: "tgsearchers7", source: Self.source())

        // 第三条没有链接 ⇒ 不是资源
        #expect(resources.count == 2)
        let first = try #require(resources.first)
        #expect(first.id == "tgsearchers7/104198")
        #expect(first.title == "仙逆（2025）4K 更新至161集")
        #expect(first.publishedAt != nil)
        #expect(first.links.count == 1)
        #expect(first.links[0].cloudType == .baidu)
        #expect(first.links[0].password == "sbez")

        let second = try #require(resources.last)
        #expect(second.title == "仙逆年番 4K 更新至161集")
        #expect(second.links[0].cloudType == .quark)
        // URL 里没有码,取正文的「提取码: 8x2k」
        #expect(second.links[0].password == "8x2k")
    }

    @Test("翻页:拿到 data-before 就再请求一次")
    func followsPagination() async throws {
        MockEmbyURLProtocol.reset()
        MockEmbyURLProtocol.stub(
            .json(Self.pageHTML, statusCode: 200), host: "t.me", path: "/s/tgsearchers7")

        let resources = try await Self.adapter().search(
            keyword: "仙逆", source: Self.source())
        // 第二页 stub 相同 ⇒ 会再解析出两条,但 `maxPages` 之后停;关键是它确实翻了页
        #expect(resources.count >= 2)
        let requests = MockEmbyURLProtocol.recordedRequests().filter { $0.url.host() == "t.me" }
        #expect(requests.count == TelegramChannelAdapter.maxPages)
        #expect(requests.last?.url.query()?.contains("before=104198") == true)
    }

    @Test("频道不存在(落在联系页)⇒ 报错,⛔ 不当成「没搜到」")
    func reportsMissingChannel() async {
        MockEmbyURLProtocol.reset()
        MockEmbyURLProtocol.stub(
            .json("<html><title>Telegram: Contact @nope</title></html>"),
            host: "t.me", path: "/s/nope")

        do {
            _ = try await Self.adapter().search(
                keyword: "仙逆", source: Self.source("nope"))
            Issue.record("应该抛错")
        } catch let error as PanResourceSearchError {
            guard case .sourceFailed(_, _, let message) = error else {
                Issue.record("错误类型不对:\(error)")
                return
            }
            #expect(message?.contains("不存在") == true)
        } catch {
            Issue.record("错误类型不对:\(error)")
        }
    }

    @Test("链接抽取:磁力 / 115 / 非网盘 URL 的处理")
    func extractsLinks() {
        let text = """
        115：https://115.com/s/swabcdef?password=1a2b
        磁力：magnet:?xt=urn:btih:abcdef&dn=x
        频道：https://t.me/other_channel
        """
        let links = PanShareLinkExtractor.links(inPlainText: text)
        #expect(links.contains { $0.cloudType == .pan115 })
        // 磁力转存不了,但它是资源,⛔ 不能吞掉
        #expect(links.contains { $0.cloudType == .magnet })
        // t.me 互推链接不算资源
        #expect(!links.contains { $0.url.contains("t.me") })
    }

    @Test("降噪:不含关键词的条目被过滤,但一条不剩时退回原结果")
    func filtersIrrelevant() {
        let relevant = PanResource(
            id: "a", title: "仙逆 4K", summary: nil, publishedAt: nil,
            links: [PanResourceLink(url: "https://pan.baidu.com/s/1a", cloudType: .baidu, password: nil)],
            sourceID: "tg", rank: nil)
        let unrelated = PanResource(
            id: "b", title: "凡人修仙传", summary: "另一个剧", publishedAt: nil,
            links: [PanResourceLink(url: "https://pan.baidu.com/s/1b", cloudType: .baidu, password: nil)],
            sourceID: "tg", rank: nil)

        let filtered = PanResourceSearchService.filterRelevant(
            [relevant, unrelated], keyword: "仙逆")
        #expect(filtered.map(\.id) == ["a"])

        // 全都不匹配 ⇒ 退回原结果,不能变成「没搜到」
        let allUnrelated = PanResourceSearchService.filterRelevant(
            [unrelated], keyword: "仙逆")
        #expect(allUnrelated.map(\.id) == ["b"])
    }
}
