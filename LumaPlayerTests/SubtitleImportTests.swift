import CoreFoundation
import XCTest
@testable import LumaPlayer

/// 本地外挂字幕:`SubtitleTextDecoder`(编码归一,纯函数)+ `SubtitleFileStore`(扩展名闸门 / 大小上限 / 编码转换 / 落盘)。
/// ⛔ 验不到:文件选择面板与沙箱授权、mpv 是否真画出这条轨(要真机,`KNOWN_ISSUES.md` B 节)。
final class SubtitleImportTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "LumaPlayer-subtitles-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - 编码归一

    func testUTF8PassesThroughUnchanged() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
        let data = Data(text.utf8)

        let result = SubtitleTextDecoder.normalize(data)

        XCTAssertEqual(result.outcome, .alreadyUTF8)
        XCTAssertEqual(result.data, data)
    }

    func testUTF8BOMIsStripped() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("1\n00:00:01,000 --> 00:00:02,000\n你好\n".utf8))

        let result = SubtitleTextDecoder.normalize(data)

        XCTAssertEqual(result.outcome, .alreadyUTF8)
        XCTAssertFalse(result.data.starts(with: [0xEF, 0xBB, 0xBF]), "BOM 必须去掉,否则首行时间码会带不可见字符")
        XCTAssertEqual(String(data: result.data, encoding: .utf8)?.contains("你好"), true)
    }

    func testGB18030IsConvertedToUTF8() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n简体中文字幕\n"
        let data = try XCTUnwrap(text.data(using: Self.gb18030))
        XCTAssertNil(String(data: data, encoding: .utf8), "前提:GB18030 字节不是合法 UTF-8")

        let result = SubtitleTextDecoder.normalize(data)

        XCTAssertEqual(result.outcome, .converted("GB18030"))
        XCTAssertEqual(String(data: result.data, encoding: .utf8), text)
    }

    func testUTF16LittleEndianWithBOMIsConverted() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nEnglish\n"
        let data = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        var withBOM = Data([0xFF, 0xFE])
        withBOM.append(data)

        let result = SubtitleTextDecoder.normalize(withBOM)

        XCTAssertEqual(result.outcome, .converted("UTF-16LE"))
        XCTAssertEqual(String(data: result.data, encoding: .utf8), text)
    }

    func testBinaryGarbageIsKeptAsIs() {
        // 0x81 是 GB18030 / BIG5 的双字节首字节,但后面的 0x20 / 0xFF 接不上;又没有像 UTF-16 的 NUL —— 三种编码都解不出
        let data = Data([0x81, 0x20, 0xFF])

        let result = SubtitleTextDecoder.normalize(data)

        XCTAssertEqual(result.outcome, .unrecognized)
        XCTAssertEqual(result.data, data, "认不出编码时必须原样保留,交给 mpv 的 uchardet")
    }

    // MARK: - 格式闸门

    func testFormatsAcceptKnownExtensionsCaseInsensitively() {
        XCTAssertTrue(SubtitleFormats.isSubtitle(fileName: "电影.chs.SRT"))
        XCTAssertTrue(SubtitleFormats.isSubtitle(fileName: "电影.ass"))
        XCTAssertTrue(SubtitleFormats.isSubtitle(fileName: "电影.sub"))
        XCTAssertFalse(SubtitleFormats.isSubtitle(fileName: "电影.mkv"))
        XCTAssertFalse(SubtitleFormats.isSubtitle(fileName: "电影"))
        XCTAssertFalse(SubtitleFormats.contentTypes.isEmpty, "选择器不能拿到空类型集合")
    }

    // MARK: - 落盘

    func testImportCopiesIntoContainerAndKeepsExtension() async throws {
        let source = directory.appending(path: "电影.chs.srt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("1\n00:00:01,000 --> 00:00:02,000\n你好\n".utf8).write(to: source)

        let store = SubtitleFileStore(directory: directory.appending(path: "store"))
        let stored = try await store.importLocalFile(at: source)

        XCTAssertEqual(stored.title, "电影.chs", "菜单名是原文件名去掉扩展名")
        XCTAssertEqual(stored.url.pathExtension, "srt")
        XCTAssertEqual(stored.encodingOutcome, .alreadyUTF8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.url.path))
        XCTAssertNotEqual(stored.url, source, "必须复制进容器,不能直接引用用户选中的原文件")
    }

    func testImportConvertsGB18030OnDisk() async throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n简体中文字幕\n"
        let source = directory.appending(path: "gbk.srt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(text.data(using: Self.gb18030)).write(to: source)

        let store = SubtitleFileStore(directory: directory.appending(path: "store"))
        let stored = try await store.importLocalFile(at: source)

        XCTAssertEqual(stored.encodingOutcome, .converted("GB18030"))
        let written = try Data(contentsOf: stored.url)
        XCTAssertEqual(String(data: written, encoding: .utf8), text, "落盘的必须是 UTF-8")
    }

    func testImportRejectsNonSubtitleFile() async throws {
        let source = directory.appending(path: "电影.mkv", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x00]).write(to: source)

        let store = SubtitleFileStore(directory: directory.appending(path: "store"))
        do {
            _ = try await store.importLocalFile(at: source)
            XCTFail("非字幕扩展名必须拒绝")
        } catch let error as SubtitleFileStore.ImportError {
            guard case .notSubtitle = error else { return XCTFail("错误类型不对:\(error)") }
        }
    }

    func testImportRejectsEmptyFile() async throws {
        let source = directory.appending(path: "empty.srt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: source)

        let store = SubtitleFileStore(directory: directory.appending(path: "store"))
        do {
            _ = try await store.importLocalFile(at: source)
            XCTFail("空文件必须拒绝")
        } catch let error as SubtitleFileStore.ImportError {
            guard case .empty = error else { return XCTFail("错误类型不对:\(error)") }
        }
    }

    func testImportRejectsOversizedFile() async throws {
        let source = directory.appending(path: "huge.srt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: SubtitleFileStore.maximumBytes + 1).write(to: source)

        let store = SubtitleFileStore(directory: directory.appending(path: "store"))
        do {
            _ = try await store.importLocalFile(at: source)
            XCTFail("超过上限必须拒绝")
        } catch let error as SubtitleFileStore.ImportError {
            guard case .tooLarge = error else { return XCTFail("错误类型不对:\(error)") }
        }
    }

    // MARK: - 工具

    private static var gb18030: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    }
}
