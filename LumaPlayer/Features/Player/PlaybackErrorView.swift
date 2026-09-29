import SwiftUI

/// 播放失败态。
///
/// 文案来自 `LoadFailure`:接口层失败(`EmbyAPIError`)与「服务端给了响应
/// 但没有可播路径」(`PlaybackError`)都要在这里说得清是哪一种,
/// 401 额外给「重新登录」入口(API_CONTRACT.md 2.5)。
struct PlaybackErrorView: View {
    let failure: LoadFailure
    var retry: () -> Void
    var dismiss: () -> Void
    /// 401 时由外层触发重新登录面板
    var login: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Metrics.spacingM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(failure.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Metrics.contentMaxWidth)
            HStack(spacing: Metrics.spacingM) {
                Button("重试") { retry() }
                    .buttonStyle(.bordered)
                if failure.needsLogin {
                    Button("重新登录") { login?() }
                        .buttonStyle(.borderedProminent)
                }
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(Metrics.spacingXL)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.panel))
    }
}
