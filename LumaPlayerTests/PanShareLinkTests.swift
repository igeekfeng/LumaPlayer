import Foundation
import Testing

@testable import LumaPlayer

/// 分享链接解析(`PanShareLink`)。这是转存的前置:解析错了就会拿错网盘的接口去调。
@Suite("分享链接解析")
struct PanShareLinkTests {

    @Test("百度短链 + 提取码")
    func baiduShortURL() throws {
        let link = try #require(PanShareLink.parse("https://pan.baidu.com/s/1AbCdEfGhIjK?pwd=abcd"))
        guard case .baidu(let short, let password) = link else {
            Issue.record("应解析成百度分享")
            return
        }
        #expect(short == "1AbCdEfGhIjK")
        #expect(password == "abcd")
        #expect(link.cloudType == .baidu)
        #expect(link.isTransferable)
    }

    @Test("百度 share/init?surl= 写法")
    func baiduSurlForm() throws {
        let link = try #require(
            PanShareLink.parse("https://pan.baidu.com/share/init?surl=1XyZ&pwd=1234"))
        guard case .baidu(let short, let password) = link else {
            Issue.record("应解析成百度分享")
            return
        }
        #expect(short == "1XyZ")
        #expect(password == "1234")
    }

    @Test("百度提取码在 fragment 里")
    func baiduFragmentPassword() throws {
        let link = try #require(PanShareLink.parse("https://pan.baidu.com/s/1AbCd#wxyz"))
        guard case .baidu(_, let password) = link else {
            Issue.record("应解析成百度分享")
            return
        }
        #expect(password == "wxyz")
    }

    @Test("115 分享码 + 密码")
    func pan115Share() throws {
        let link = try #require(PanShareLink.parse("https://115.com/s/swabc123?password=4321"))
        guard case .pan115(let code, let receiveCode) = link else {
            Issue.record("应解析成 115 分享")
            return
        }
        #expect(code == "swabc123")
        #expect(receiveCode == "4321")
        #expect(link.cloudType == .pan115)
        #expect(link.isTransferable)
    }

    @Test("115 无密码时提取码是空串,不是 nil")
    func pan115WithoutPassword() throws {
        let link = try #require(PanShareLink.parse("https://115cdn.com/s/swxyz"))
        guard case .pan115(let code, let receiveCode) = link else {
            Issue.record("应解析成 115 分享")
            return
        }
        #expect(code == "swxyz")
        #expect(receiveCode == "")
    }

    @Test("夸克认得出但不能转存")
    func quarkIsNotTransferable() throws {
        let link = try #require(PanShareLink.parse("https://pan.quark.cn/s/abcdef"))
        #expect(link.cloudType == .quark)
        #expect(!link.isTransferable)
        // ⛔ 不能只说「不支持」,要说清是哪一家的什么限制
        let reason = try #require(link.unsupportedReason)
        #expect(reason.contains("夸克"))
    }

    @Test("带说明文字的链接也能抠出来")
    func extractsURLFromProse() throws {
        let link = try #require(
            PanShareLink.parse("仙逆 全集 https://pan.baidu.com/s/1QqWwEe?pwd=9z8y 提取码:9z8y"))
        guard case .baidu(let short, let password) = link else {
            Issue.record("应解析成百度分享")
            return
        }
        #expect(short == "1QqWwEe")
        #expect(password == "9z8y")
    }

    @Test("认不出的域名当其它网盘,不猜")
    func unknownHost() throws {
        let link = try #require(PanShareLink.parse("https://example.com/s/abc"))
        guard case .other(let type, _) = link else {
            Issue.record("应解析成其它网盘")
            return
        }
        #expect(type == .unknown)
        #expect(!link.isTransferable)
    }

    @Test("不是链接就返回 nil")
    func notAURL() {
        #expect(PanShareLink.parse("这是一段没有链接的说明") == nil)
    }
}

/// 网盘类型判定
@Suite("网盘类型")
struct PanCloudTypeTests {
    @Test("按域名判类型")
    func detectByHost() {
        #expect(PanCloudType.detect(fromHost: "pan.baidu.com") == .baidu)
        #expect(PanCloudType.detect(fromHost: "pan.quark.cn") == .quark)
        #expect(PanCloudType.detect(fromHost: "115.com") == .pan115)
        #expect(PanCloudType.detect(fromHost: "www.aliyundrive.com") == .aliyun)
        #expect(PanCloudType.detect(fromHost: "unknown.example") == .unknown)
    }

    @Test("磁力与 ed2k 不可转存")
    func magnetNotTransferable() {
        #expect(!PanCloudType.magnet.isTransferable)
        #expect(!PanCloudType.ed2k.isTransferable)
        #expect(PanCloudType.baidu.isTransferable)
    }
}
