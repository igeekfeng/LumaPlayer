import Foundation

/// 章节 / 片头片尾标记(ChapterInfo,API_CONTRACT.md 4.3.1)。全部可选(8.1):
/// 老版本服务器没有 `MarkerType`,不能因此整条解码失败。
struct EmbyChapter: Decodable, Sendable, Equatable {
    let startPositionTicks: Int64?
    let name: String?
    /// `Chapter` / `IntroStart` / `IntroEnd` / `CreditsStart`。按自由字符串解,枚举外的值不能让 PlaybackInfo 解码失败。
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
