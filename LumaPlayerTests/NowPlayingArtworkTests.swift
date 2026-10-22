import AppKit
import MediaPlayer
import XCTest
@testable import LumaPlayer

/// MediaPlayer 在自己的 accessQueue 上调 `requestHandler`;闭包若继承 `NowPlayingController` 的 `@MainActor` 隔离,
/// 运行时隔离检查会 trap。这里在后台队列取封面复现该调用方式,回归时测试进程直接崩掉。
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
