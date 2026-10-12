import Foundation

/// 用户手动标注的片头 / 片尾(存**原始意图**,允许暂时只填一半)。
///
/// 为什么要有它:Emby 的片头检测要 Premiere、片尾靠插件,服务端也**没有写回章节标记的
/// 接口**(`API_CONTRACT.md` 4.3.1 只读),所以「检测不出来时自己标一个」只能记在本地
/// (`docs/KNOWN_ISSUES.md` Q30)。
///
/// 与 `PlaybackMarkers` 的分工:`PlaybackMarkers` 是**校验后**的结果(片头必须是合法区间);
/// 这里保留三个原始位置,好让编辑面板回显「只填了起点」这种中间状态,校验统一交给
/// `PlaybackMarkers(introStart:introEnd:creditsStart:)`。
///
/// 作用范围是**同一部剧**(见 `ManualMarkersScope`):同一部剧的每一集共用一份。
struct ManualMarkers: Codable, Sendable, Equatable {
    /// 片头起点(秒);nil = 没标
    var introStart: Double?
    /// 片头终点(秒);nil = 没标
    var introEnd: Double?
    /// 片尾起点(秒);nil = 没标
    var creditsStart: Double?
    /// 最后一次修改时刻(诊断用)
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

    /// 三个位置一个都没标(等价于「没设过」:落库时应删条目而不是留一个空壳)。
    var isEmpty: Bool {
        introStart == nil && introEnd == nil && creditsStart == nil
    }

    /// 覆盖服务端标记,**按标记组**:
    /// - 用户动过片头(`introStart` / `introEnd` 任一非 nil)→ 片头整组取手动;
    ///   不完整 / 非法时结果为 nil(用户既然要自己标,就不该再混进服务端那组);
    /// - 用户设过片尾 → 取手动;
    /// - 没动过的那一组沿用 `server`。
    ///
    /// 为什么不逐字段混:片头的起点与终点是**一对**,拿手动的起点配服务端的终点会拼出一个
    /// 谁都没标过的区间。片头与片尾之间则互不相干,分开覆盖才不会「只标了片尾就把服务端的
    /// 片头一起抹掉」。
    func applying(to server: PlaybackMarkers) -> PlaybackMarkers {
        let manual = PlaybackMarkers(
            introStart: introStart, introEnd: introEnd, creditsStart: creditsStart)
        let introTouched = introStart != nil || introEnd != nil
        return PlaybackMarkers(
            intro: introTouched ? manual.intro : server.intro,
            creditsStart: creditsStart != nil ? manual.creditsStart : server.creditsStart)
    }
}
