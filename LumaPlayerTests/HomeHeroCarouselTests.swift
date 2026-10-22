import XCTest
@testable import LumaPlayer

/// 首页 hero 轮播的纯逻辑(`HomeHeroCarousel`):绕回与「何时不该自动切」,两者在界面上都难看出错。
/// 定时器本身不测:它唯一的变量就是 `wrap` 的输入。
@MainActor
final class HomeHeroCarouselTests: XCTestCase {

    // MARK: - 走到头绕回

    func testAdvancesForward() {
        XCTAssertEqual(HomeHeroCarousel.wrap(0, by: 1, count: 5), 1)
        XCTAssertEqual(HomeHeroCarousel.wrap(3, by: 1, count: 5), 4)
    }

    func testWrapsForwardFromLast() {
        XCTAssertEqual(HomeHeroCarousel.wrap(4, by: 1, count: 5), 0)
    }

    /// Swift 的 `%` 对负数给负余数,少加一轮 count 就是 -1(下标崩溃)
    func testWrapsBackwardFromFirst() {
        XCTAssertEqual(HomeHeroCarousel.wrap(0, by: -1, count: 5), 4)
    }

    func testWrapsBackwardMoreThanOneRound() {
        XCTAssertEqual(HomeHeroCarousel.wrap(3, by: -5, count: 4), 2)
        XCTAssertEqual(HomeHeroCarousel.wrap(1, by: -10, count: 3), 0)
    }

    func testWrapsForwardMoreThanOneRound() {
        XCTAssertEqual(HomeHeroCarousel.wrap(1, by: 7, count: 3), 2)
    }

    func testSingleItemNeverMoves() {
        XCTAssertEqual(HomeHeroCarousel.wrap(0, by: 1, count: 1), 0)
        XCTAssertEqual(HomeHeroCarousel.wrap(0, by: -1, count: 1), 0)
    }

    func testEmptyCannotIndex() {
        XCTAssertEqual(HomeHeroCarousel.wrap(0, by: 1, count: 0), 0)
    }

    // MARK: - 什么时候该自动切

    func testAutoAdvancesOnlyWhenEveryConditionHolds() {
        XCTAssertTrue(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 3, reduceMotion: false, isHovering: false, isWindowActive: true))
    }

    func testDoesNotAutoAdvanceWithSingleItem() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 1, reduceMotion: false, isHovering: false, isWindowActive: true))
    }

    /// 「减弱动态效果」要停的是内容自动变化,不只是动画
    func testDoesNotAutoAdvanceWhenReduceMotion() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 3, reduceMotion: true, isHovering: false, isWindowActive: true))
    }

    func testPausesWhileHovering() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 3, reduceMotion: false, isHovering: true, isWindowActive: true))
    }

    func testPausesWhenWindowIsNotKey() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 3, reduceMotion: false, isHovering: false, isWindowActive: false))
    }
}
