import Foundation

/// 拖动进度这件事怎么实现。**它不等于「是不是转码」**:
///
/// - Emby 的 DirectStream 与 Transcode 都有解:前者客户端 seek,后者停流 +
///   `StartTimeTicks` 重新起流(API_CONTRACT.md 4.5);
/// - 百度源的直连流同样能客户端 seek(`dlink` 走普通 https,CDN 支持 `Range`),
///   但它的**转码流没有解** —— `method=streaming` 没有起流位置之类的参数,
///   重新请求只会从头开始(`docs/BAIDU_PAN_API.md` §2.3)。
///
/// 所以「能不能拖」必须**显式带在会话上**,⛔ 不能靠 `plan.method` 反推:
/// 同一个 `.transcode` 在 Emby 侧可拖(重新起流)、在百度侧不可拖。
/// 反推错的代价是「拖到 30 分钟,画面回到 0:00,进度被写成 0」——
/// 一个既静默又污染进度的错(CLAUDE.md 硬规则 4)。
enum PlaybackSeekStrategy: Sendable, Equatable {
    /// 静态文件:交给播放内核 seek(精度最高)
    case clientSeek
    /// 停旧流 + 带起流点重新取一路(Emby 的转码)
    case restartStream
    /// 没有可行方案。带一句给用户看的理由 —— 由播放层显示,⛔ 不装作拖成功了。
    case unsupported(reason: String)

    /// 能不能拖。进度条与方向键据此决定要不要给交互。
    var allowsSeeking: Bool {
        if case .unsupported = self { return false }
        return true
    }

    /// 不可拖动时的理由(可以拖动时为 nil)
    var unavailableReason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}
