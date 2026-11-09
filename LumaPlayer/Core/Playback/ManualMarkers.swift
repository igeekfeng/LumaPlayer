import Foundation

/// 用户手动标注的片头 / 片尾,只存本地(服务端章节标记只读,`API_CONTRACT.md` 4.3.1、Q30)。
///
/// 存用户填的原始位置(秒,nil = 这一格没填),让编辑面板能回显只填了一半的状态;
/// 生效的区间由 `asPlaybackMarkers` 算,校验仍交给 `PlaybackMarkers`。
/// 同一部剧的每一集共用一份(`ManualMarkersScope`)。
struct ManualMarkers: Codable, Sendable, Equatable {
    var introStart: Double?
    var introEnd: Double?
    /// 片尾固定时刻(从片首算秒)。旧记录用;新标注用 `creditsLead`。
    var creditsStart: Double?
    /// 片尾距结尾时长(秒)。同一部剧每集长度不同,手动标注用这个,跨集自动适配。
    var creditsLead: Double?
    /// 诊断用
    var updatedAt: Date

    init(
        introStart: Double? = nil,
        introEnd: Double? = nil,
        creditsStart: Double? = nil,
        creditsLead: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.introStart = introStart
        self.introEnd = introEnd
        self.creditsStart = creditsStart
        self.creditsLead = creditsLead
        self.updatedAt = updatedAt
    }

    /// 等价于没设过:落库时删条目,不留空壳。
    var isEmpty: Bool {
        introStart == nil && introEnd == nil && creditsStart == nil && creditsLead == nil
    }

    /// 手动标注有没有碰过片尾(两种形式任一)。
    var creditsTouched: Bool { creditsStart != nil || creditsLead != nil }

    /// 当前片尾的表达方式(编辑面板回显用)。`creditsLead` 优先。
    var creditsReference: PlaybackMarkers.Credits? {
        if let lead = creditsLead { return .beforeEnd(lead) }
        if let start = creditsStart { return .at(start) }
        return nil
    }

    /// 这套标注生效后的标记组。片头起点留空按 00:00 计:片头从片首开始是常态,
    /// 边看边只点「设为片头终点」也该能跳,⛔ 不逼用户倒回片首补起点。
    /// 终点缺失 / 不晚于起点时整组仍为 nil(由 `PlaybackMarkers` 判定)。
    var asPlaybackMarkers: PlaybackMarkers {
        PlaybackMarkers(
            introStart: introStart ?? 0, introEnd: introEnd, credits: creditsReference)
    }

    /// 按组覆盖服务端标记:动过片头(起 / 止任一非 nil)则片头整组取手动,不完整 / 非法时为 nil;
    /// 设过片尾则片尾取手动;没动的组沿用 `server`。
    /// ⛔ 不逐字段混:手动起点配服务端终点会拼出谁都没标过的区间。
    func applying(to server: PlaybackMarkers) -> PlaybackMarkers {
        let manual = asPlaybackMarkers
        let introTouched = introStart != nil || introEnd != nil
        return PlaybackMarkers(
            intro: introTouched ? manual.intro : server.intro,
            credits: creditsTouched ? manual.credits : server.credits)
    }
}
