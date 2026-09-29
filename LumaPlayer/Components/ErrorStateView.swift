import SwiftUI

/// 页面级错误状态:图标 + 文本 + 操作。
///
/// 颜色不是错误状态的唯一表达(UI_DESIGN.md 7.2),因此图标与文案都在;
/// 401 时给「重新登录」而不是「重试」—— 重试一个必然被拒的请求没有意义
/// (API_CONTRACT.md 2.5:401 = token 失效,没有 refresh 机制)。
struct ErrorStateView: View {
    let failure: LoadFailure
    let retry: () -> Void
    var login: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Metrics.spacingM) {
            Image(systemName: failure.needsLogin ? "person.crop.circle.badge.exclam" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(failure.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Metrics.contentMaxWidth)
            HStack(spacing: Metrics.spacingM) {
                if failure.needsLogin {
                    Button("重新登录") { login?() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("重试") { retry() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.spacingXL)
    }
}
