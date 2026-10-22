import Foundation

/// 用户手动标注的片头 / 片尾,只存本地(服务端章节标记只读,`API_CONTRACT.md` 4.3.1、Q30)。
///
/// 存未校验的原始位置(秒,nil = 没标),让编辑面板能回显只填了一半的状态;
/// 校验交给 `PlaybackMarkers(introStart:introEnd:creditsStart:)`。
/// 同一部剧的每一集共用一份(`ManualMarkersScope`)。
struct ManualMarkers: Codable, Sendable, Equatable {
    var introStart: Double?
    var introEnd: Double?
    var creditsStart: Double?
    /// 诊断用
    var updatedAt: Date

    init(
        introStart: Double? = nil,
        introEnd: Double? = nil,
        creditsStart: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.introStart = introStart
        self.introEnd = introEnd
        self.creditsStart = creditsStart
        self.updatedAt = updatedAt
    }

    /// 等价于没设过:落库时删条目,不留空壳。
    var isEmpty: Bool {
        introStart == nil && introEnd == nil && creditsStart == nil
    }

    /// 按组覆盖服务端标记:动过片头(起 / 止任一非 nil)则片头整组取手动,不完整 / 非法时为 nil;
    /// 设过片尾则片尾取手动;没动的组沿用 `server`。
    /// ⛔ 不逐字段混:手动起点配服务端终点会拼出谁都没标过的区间。
    func applying(to server: PlaybackMarkers) -> PlaybackMarkers {
        let manual = PlaybackMarkers(
            introStart: introStart, introEnd: introEnd, creditsStart: creditsStart)
        let introTouched = introStart != nil || introEnd != nil
        return PlaybackMarkers(
            intro: introTouched ? manual.intro : server.intro,
            creditsStart: creditsStart != nil ? manual.creditsStart : server.creditsStart)
    }
}
