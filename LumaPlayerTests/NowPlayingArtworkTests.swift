import AppKit
import MediaPlayer
import XCTest
@testable import LumaPlayer

/// 「正在播放」封面的 `requestHandler` 由 MediaPlayer 在它自己的 accessQueue 上调用。
/// 该闭包曾继承 `NowPlayingController` 的 `@MainActor` 隔离,被后台队列调用时
/// 运行时隔离检查直接 trap —— 表现为播放有剧照的分集时 App 崩溃。
///
/// 这里在后台队列取封面图,复现 MediaPlayer 的调用方式;回归时测试进程会直接崩掉。
final class NowPlayingArtworkTests: XCTestCase {

    func testArtworkHandlerCanBeCalledOffMainThread() {
        let done = expectation(description: "artwork requested off main")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            let artwork = NowPlayingController.makeArtwork(NSImage(size: NSSize(width: 16, height: 9)))
            let result = artwork.image(at: NSSize(width: 16, height: 9))
            XCTAssertNotNil(result)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
