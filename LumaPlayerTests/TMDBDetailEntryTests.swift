import CoreGraphics
import SwiftUI
import XCTest
@testable import LumaPlayer

/// 详情页底部的「在 TMDB 上打开」:站点地址拼法、入口出现条件、官方字标的离屏渲染。
/// ⛔ 零真实网络:这里不请求任何 TMDB 接口,只断言拼出来的 URL。
@MainActor
final class TMDBDetailEntryTests: XCTestCase {

    // MARK: - 站点地址(`docs/TMDB_API.md` §13)

    func testMoviePageURLCarriesLanguageQueryNotPathSegment() {
        let url = try? XCTUnwrap(TMDBPage.movieURL(id: 550))
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.themoviedb.org")
        XCTAssertEqual(url?.path, "/movie/550")
        // ⚠️ 语言走查询串:路径里的 `/zh-CN/` 实测 404
        XCTAssertEqual(queryValue(url, "language"), "zh-CN")
    }

    func testSeriesPageURLUsesTVPath() {
        let url = TMDBPage.seriesURL(id: 1399)
        XCTAssertEqual(url?.path, "/tv/1399")
        XCTAssertEqual(queryValue(url, "language"), TMDBClient.defaultLanguage)
    }

    // MARK: - Emby 侧:只有剧级条目才给入口

    func testMovieAndSeriesUseTheirOwnPath() {
        XCTAssertEqual(emby(type: "Movie", providerIds: ["Tmdb": "550"]).tmdbPageURL?.path, "/movie/550")
        XCTAssertEqual(emby(type: "Series", providerIds: ["Tmdb": "1399"]).tmdbPageURL?.path, "/tv/1399")
    }

    /// 分集的 `ProviderIds.Tmdb` 是**单集** id,站点地址要剧级 id —— ⛔ 拼一个错页面。
    func testEpisodeAndSeasonGetNoEntry() {
        XCTAssertNil(emby(type: "Episode", providerIds: ["Tmdb": "63056"]).tmdbPageURL)
        XCTAssertNil(emby(type: "Season", providerIds: ["Tmdb": "3624"]).tmdbPageURL)
    }

    func testMissingOrDirtyProviderIDGivesNoEntry() {
        XCTAssertNil(emby(type: "Series", providerIds: nil).tmdbPageURL)
        XCTAssertNil(emby(type: "Series", providerIds: ["Tmdb": "abc"]).tmdbPageURL)
        XCTAssertNil(emby(type: "Series", providerIds: ["Tmdb": "0"]).tmdbPageURL)
        // 键名大小写由 `EmbyItem.tmdbID` 统一按小写比较
        XCTAssertEqual(emby(type: "Series", providerIds: ["tmdb": "1399"]).tmdbPageURL?.path, "/tv/1399")
    }

    // MARK: - 网盘 / 本地文件夹侧

    func testMatchKindDecidesThePath() {
        XCTAssertEqual(TMDBMatch(result: Self.result(id: 1399), kind: .tv).tmdbPageURL?.path, "/tv/1399")
        XCTAssertEqual(TMDBMatch(result: Self.result(id: 550), kind: .movie).tmdbPageURL?.path, "/movie/550")
    }

    // MARK: - 官方字标

    /// 官方画布是 273.42×35.52;字标按高度定宽,比例不能走样。
    func testGeometryKeepsOfficialAspectRatio() {
        XCTAssertEqual(TMDBGeometry.aspect, 35.52 / 273.42, accuracy: 1e-9)
    }

    /// 离屏渲染:字标真的画出来了,且渐变从左(偏绿)到右(偏蓝)走完全程。
    func testRendersOfficialGradientFromLeftToRight() {
        let height: CGFloat = 120
        let width = height / TMDBGeometry.aspect
        let renderer = ImageRenderer(content: TMDBLogoMark(height: height))
        renderer.scale = 1
        guard let image = try? XCTUnwrap(renderer.cgImage) else { return }
        XCTAssertEqual(Double(image.height), Double(height), accuracy: 2)
        XCTAssertEqual(Double(image.width), Double(width), accuracy: 2)

        guard let buffer = rasterize(image) else { return XCTFail("无法栅格化 CGImage") }
        let w = image.width
        let h = image.height
        // 逐列统计「有像素」的列范围,再用左右两端的平均色确认渐变方向。
        var leftSum = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        var rightSum = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = Double(buffer[i + 3])
                guard a > 32 else { continue }
                let r = Double(buffer[i]) / a
                let g = Double(buffer[i + 1]) / a
                let b = Double(buffer[i + 2]) / a
                if x < w / 10 {
                    leftSum = (leftSum.r + r, leftSum.g + g, leftSum.b + b, leftSum.n + 1)
                } else if x >= w - w / 10 {
                    rightSum = (rightSum.r + r, rightSum.g + g, rightSum.b + b, rightSum.n + 1)
                }
            }
        }
        XCTAssertGreaterThan(leftSum.n, 0, "左端没有画出像素")
        XCTAssertGreaterThan(rightSum.n, 0, "右端没有画出像素")
        let left = (r: leftSum.r / leftSum.n, g: leftSum.g / leftSum.n, b: leftSum.b / leftSum.n)
        let right = (r: rightSum.r / rightSum.n, g: rightSum.g / rightSum.n, b: rightSum.b / rightSum.n)
        // 官方渐变 #90CEA1 → #00B3E5:绿色份额下降、蓝色份额上升
        XCTAssertGreaterThan(left.g - left.b, right.g - right.b, "左端应更偏绿")
        XCTAssertGreaterThan(right.b - right.g, left.b - left.g, "右端应更偏蓝")
    }

    // MARK: - 辅助

    private func emby(type: String, providerIds: [String: String]?) -> EmbyItem {
        EmbyItem(
            id: "ITEM-1",
            name: "Test",
            type: type,
            overview: nil,
            productionYear: nil,
            runTimeTicks: nil,
            indexNumber: nil,
            parentIndexNumber: nil,
            seasonID: nil,
            seriesID: nil,
            seriesName: nil,
            seasonName: nil,
            genres: nil,
            communityRating: nil,
            officialRating: nil,
            imageTags: nil,
            primaryImageTag: nil,
            backdropImageTags: nil,
            parentBackdropItemID: nil,
            parentBackdropImageTags: nil,
            parentLogoItemID: nil,
            parentLogoImageTag: nil,
            parentThumbItemID: nil,
            parentThumbImageTag: nil,
            userData: nil,
            people: nil,
            studios: nil,
            taglines: nil,
            premiereDate: nil,
            childCount: nil,
            criticRating: nil,
            mediaStreams: nil,
            providerIds: providerIds
        )
    }

    private static func result(id: Int) -> TMDBResult {
        TMDBResult(tmdbID: id)
    }

    private func queryValue(_ url: URL?, _ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            .flatMap { $0.queryItems?.first { $0.name == name }?.value }
    }

    private func rasterize(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
