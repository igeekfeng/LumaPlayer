import Foundation

/// 把 Rust 的播放决策结果转成播放层要的 `PlaybackPlan`(`exp/avkit-rust-core`)。
///
/// ## 为什么单独一个类型
///
/// 决策本身已经全在 Rust(`luma-emby::decision`),换栈之后 Swift 侧只剩两件
/// **本地**的事:
///
/// 1. **拼 URL**(`PlaybackURLBuilder`,API_CONTRACT.md 4.5)—— 需要站点根与
///    `/emby` 前缀,那是 Swift 侧探测出来的;
/// 2. **挂认证头**(第 6 节)—— token 在 Swift 的凭据存储里。
///
/// 这两件事不该散落在播放窗口与自检脚本里各写一遍,所以收在这里:
/// 播放窗口(P3b)与 `Scripts/verify-avkit-playback.sh` 走同一条路径。
///
/// ⚠️ 与 `PlaybackDecisionEngine`(Swift)的关系:那一份会自己解响应、自己做
/// 4.4 的六步,是 libmpv 时代的产物。本分支上决策已改由 Rust 承担,本类型是它的
/// 接替者;旧引擎目前**没有调用点**,等 P3b 接通播放窗口时删除
/// (文档 8.2「本阶段的诚实边界」已记这一条)。
///
/// ⚠️ 已知缺口:DirectStream 的 URL **只认服务端给的 `DirectStreamUrl`**,没有
/// 旧引擎那条「自拼 `/Videos/{Id}/stream.{ext}`」的退路 —— 那条退路需要
/// `MediaSource.Container`,而 FFI 决策结果里没有这个字段。要不要把它补进决策结果
/// 留待 P3b 定夺;在那之前,服务端不给 `DirectStreamUrl` 就是如实报错,不猜扩展名。
enum PlaybackPlanBuilder {

    /// - Parameters:
    ///   - decision: Rust 决策结果(已含逐维度判定与「该不该给直连」的守卫)
    ///   - urlBuilder: 站点根 + `/emby` 前缀
    ///   - headers: 认证头(API_CONTRACT.md 第 6 节);含 token,⛔ 不得进日志
    static func plan(
        from decision: PlaybackDecisionFfi,
        urlBuilder: PlaybackURLBuilder,
        headers: [String: String]
    ) throws -> PlaybackPlan {
        switch decision.method {
        case PlaybackMethod.directStream.rawValue:
            // ⛔ 不自拼地址:猜扩展名等于替服务端决定输出格式,而自拼的
            // `/stream.{ext}?static=true` 在带网关的服务器上会拿到
            // 200 + JSON 错误体(API_CONTRACT.md 4.5 / issue #2)。
            guard let raw = decision.directStreamUrl,
                  let url = urlBuilder.directStreamURL(serverProvided: raw) else {
                throw PlaybackError.urlConstructionFailed
            }
            return .directStream(
                url: url,
                headers: headers,
                playSessionID: decision.playSessionId,
                mediaSourceID: decision.mediaSourceId
            )

        case PlaybackMethod.transcode.rawValue:
            guard let relative = decision.transcodingUrl,
                  let url = urlBuilder.transcodeURL(relativePath: relative) else {
                throw PlaybackError.urlConstructionFailed
            }
            return .transcode(
                url: url,
                headers: headers,
                playSessionID: decision.playSessionId,
                mediaSourceID: decision.mediaSourceId
            )

        default:
            // 取值只有上面两个(`PlaybackMethod.wire_name`)。走到这里说明 FFI
            // 两侧的字符串漂移了 —— ⛔ 不按「大概是转码」糊过去。
            throw PlaybackError.unknownDecisionMethod(name: decision.method)
        }
    }
}
