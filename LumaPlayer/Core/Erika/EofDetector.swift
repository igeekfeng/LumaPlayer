import Foundation

/// 判定「播放已结束」的纯逻辑(**只吃归一化事件,可脱离内核单测**)。
///
/// ## 为什么需要它
/// 当前内核(Erika)**没有独立的 EOF 事件,也没有「已结束」状态**:文档只说
/// 「`PositionChanged` 在 seek / play / EOF 时另发一次」,结束多半伴随一次
/// `StateChanged`。所以「自然播完」要靠推断:位置到过末尾 + 收到停止态。
///
/// ⚠️ **待真机核实**:EOF 究竟落在哪个状态(`stopped` / `closed`)、是否总会先来
/// 一次到末尾的 `positionChanged`。核实后只改本文件即可,上层不受影响。
/// 登记在 docs/KNOWN_ISSUES.md。
///
/// ## 判定规则
/// - 记录 `duration`,位置到过 `duration - 容差` 就算 `reachedEnd`;
/// - 收到 `stopped` / `closed` 态时:若这次停止是**我们主动发起的**
///   (`markLocalStop()`),报 `.stopped`;否则按 `reachedEnd` 报 `.eof` 或 `.stopped`;
/// - 只报一次。
struct EofDetector {

    /// 判定「已到末尾」的位置容差(秒)。seek 落点误差很小,0.5 秒足够,
    /// 又不会把「拖到接近结尾」误判成播完。
    static let eofPositionEpsilon: Double = 0.5

    private var duration: Double = 0
    private var reachedEnd = false
    private var locallyStopped = false
    private var didReport = false

    /// 上层主动停止 / 关闭前调用:之后的停止态不再算「自然播完」。
    mutating func markLocalStop() {
        locallyStopped = true
    }

    /// 喂一个归一化事件;返回非 nil 表示播放已结束(至多返回一次)。
    mutating func observe(_ event: PlayerEvent) -> PlayerEndReason? {
        guard !didReport else { return nil }
        switch event {
        case .duration(let value):
            duration = value

        case .position(let value):
            if duration > 0, value >= duration - Self.eofPositionEpsilon {
                reachedEnd = true
            }

        case .phaseChanged(.stopped), .phaseChanged(.closed):
            didReport = true
            if locallyStopped { return .stopped }
            return reachedEnd ? .eof : .stopped

        case .ended(let reason):
            didReport = true
            return reason

        default:
            break
        }
        return nil
    }
}
