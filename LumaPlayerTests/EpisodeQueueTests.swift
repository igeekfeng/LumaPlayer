import XCTest
@testable import LumaPlayer

/// 播放页上一集 / 下一集 / 选集面板都建在它上面,边界最容易写错。
final class EpisodeQueueTests: XCTestCase {

    func testWalksTheList() {
        let queue = makeQueue(currentIndex: 1)
        XCTAssertEqual(queue.current?.id, "2")
        XCTAssertEqual(queue.previous?.id, "1")
        XCTAssertEqual(queue.next?.id, "3")
    }

    /// ⛔ 不绕回。
    func testFirstHasNoPreviousAndLastHasNoNext() {
        XCTAssertNil(makeQueue(currentIndex: 0).previous)
        XCTAssertEqual(makeQueue(currentIndex: 0).next?.id, "2")
        XCTAssertEqual(makeQueue(currentIndex: 2).previous?.id, "2")
        XCTAssertNil(makeQueue(currentIndex: 2).next)
    }

    /// 下标为 nil / 越界时 ⛔ 不猜一个邻居。
    func testUnresolvedIndexYieldsNoNeighbours() {
        let unresolved = EpisodeQueue(episodes: makeEpisodes(), currentIndex: nil)
        XCTAssertNil(unresolved.current)
        XCTAssertNil(unresolved.previous)
        XCTAssertNil(unresolved.next)

        let outOfRange = EpisodeQueue(episodes: makeEpisodes(), currentIndex: 99)
        XCTAssertNil(outOfRange.current)
        XCTAssertNil(outOfRange.previous)
        XCTAssertNil(outOfRange.next)
    }

    /// 成员与顺序原样保留。
    func testSelectingMovesTheIndexWithoutReordering() {
        let queue = makeQueue(currentIndex: 0)
        let selected = queue.selecting(queue.episodes[2])

        XCTAssertEqual(selected?.current?.id, "3")
        XCTAssertEqual(selected?.episodes.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(selected?.previous?.id, "2")
        XCTAssertNil(selected?.next)
    }

    /// Emby 跨季边界集就是这样,由新播放页自己重新定位。
    func testSelectingUnknownEpisodeReturnsNil() {
        let queue = makeQueue(currentIndex: 0)
        let outsider = PlaybackEpisode(
            id: "99", label: nil, title: "别的剧", source: .baiduPan(file: makeFile(fsID: 99)))
        XCTAssertNil(queue.selecting(outsider))
    }

    // MARK: - 夹具

    private func makeQueue(currentIndex: Int?) -> EpisodeQueue {
        EpisodeQueue(episodes: makeEpisodes(), currentIndex: currentIndex)
    }

    private func makeEpisodes() -> [PlaybackEpisode] {
        (1...3).map { index in
            PlaybackEpisode(
                id: String(index),
                label: "第 \(index) 集",
                title: "示例",
                source: .baiduPan(file: makeFile(fsID: UInt64(index)))
            )
        }
    }

    private func makeFile(fsID: UInt64) -> BaiduPanFile {
        BaiduPanFile(
            fsID: fsID,
            path: "/apps/LumaPlayer/\(fsID).mp4",
            name: "\(fsID).mp4",
            sizeBytes: nil,
            isDirectory: false,
            category: nil,
            modifiedAt: nil,
            thumbnailURL: nil
        )
    }
}
