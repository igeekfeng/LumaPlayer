import Foundation

/// 章节 / 片头片尾标记(ChapterInfo,API_CONTRACT.md 4.3.1)。
///
/// 字段来源:dev.emby.media 的 PlaybackInfo 页(`MediaSourceInfo.Chapters: ChapterInfo[]`,
/// ChapterInfo = `StartPositionTicks` / `Name` / `ImageTag` / `MarkerType` / `ChapterIndex`);
/// 本地开发实例 4.9.5.0 实测单项接口与 PlaybackInfo 的 MediaSource 都带这个数组
/// (API_CONTRACT.md 4.3.1)。
///
/// 可选性按 8.1:全部可选 —— 旧版本(官方 OpenAPI 4.1.1.0)的 ChapterInfo
/// 只有前三个字段,没有 `MarkerType` 也不能整条解码失败。
struct EmbyChapter: Decodable, Sendable, Equatable {
    let startPositionTicks: Int64?
    let name: String?
    /// `Chapter` / `IntroStart` / `IntroEnd` / `CreditsStart`(官方文档列出的四个值)。
    /// 按自由字符串解:服务端给出枚举外的值时只是不认识,不该让整个 PlaybackInfo 解码失败。
    let markerType: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case markerType = "MarkerType"
    }
}

extension EmbyChapter {
    enum Marker {
        static let introStart = "IntroStart"
        static let introEnd = "IntroEnd"
        static let creditsStart = "CreditsStart"
    }
}
