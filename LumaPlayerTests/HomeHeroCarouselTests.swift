import XCTest
@testable import LumaPlayer

/// 首页 hero 轮播的**纯逻辑**(`HomeHeroCarousel`)。
///
/// 轮播的状态机只有两件事会错,而两件都很难在界面上看出来:
/// 走到头之后怎么绕回去(错了只是「有时不换」),以及什么时候**不该**自动切
/// (错了是「用户正在读文字,内容被换掉了」)。所以两条都抽成静态纯函数测。
///
/// ⛔ 定时器本身(8 秒一次)不在这里测:那要靠注入时钟才稳,
/// 而它唯一的变量就是这个 `wrap` 的输入 —— 时间驱动不值得再搭一套替身。
@MainActor
final class HomeHeroCarouselTests: XCTestCase {

    // MARK: - 走到头绕回

    func testAdvancesForward() {
        XCTAssertEqual(HomeHeroCarousel.wrap(0, by: 1, count: 5), 1)
        XCTAssertEqual(HomeHeroCarousel.wrap(3, by: 1, count: 5), 4)
    }

    /// 最后一张往后 = 第一张(不是停在原地,也不是越界)
    func testWrapsForwardFromLast() {
        XCTAssertEqual(HomeHeroCarousel.wrap(4, by: 1, count: 5), 0)
    }

    /// 第一张往前 = 最后一张。⚠️ Swift 的 `%` 对负数给负余数,
    /// 少加一轮 count 就会得到 -1(数组下标崩溃)
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

    /// 只有一张 / 一张都没有:恒定返回 0,不越界
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

    /// 只有一张:不轮播(控件也不给),不该有定时器在空转
    func testDoesNotAutoAdvanceWithSingleItem() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 1, reduceMotion: false, isHovering: false, isWindowActive: true))
    }

    /// 系统开了「减弱动态效果」:连内容自动变化都该停(不只是动画)
    func testDoesNotAutoAdvanceWhenReduceMotion() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 3, reduceMotion: true, isHovering: false, isWindowActive: true))
    }

    /// 指针停在 hero 上:面板正在被读,或在瞄「播放」按钮 ——
    /// 内容在手底下换掉是最难受的一种
    func testPausesWhileHovering() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 3, reduceMotion: false, isHovering: true, isWindowActive: true))
    }

    /// 窗口不是 key(切到别的 App):不该继续拉图片
    func testPausesWhenWindowIsNotKey() {
        XCTAssertFalse(HomeHeroCarousel.shouldAutoAdvance(
            itemCount: 3, reduceMotion: false, isHovering: false, isWindowActive: false))
    }
}
