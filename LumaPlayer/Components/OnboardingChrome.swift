import SwiftUI

// 表单外壳:添加服务器 / 重新登录 / 编辑服务器共用。

/// 表单顶部:图标 + 标题。
///
/// ⚠️ `subtitle` **只收错误 / 阻塞原因**(例如「连不上」),⛔ 不收「这一页是干什么的」这类讲解 ——
/// 表单自己的字段已经说明了。图标有三种来源:SF Symbol(`systemImage:`),或带自家品牌配色的矢量标记
/// (`pan115Title:` / `baiduTitle:`)——后者⛔ 不能再套 tint 着色,否则官方配色会被强调色盖掉。
struct OnboardingFormHeader: View {
    private enum Mark {
        case symbol(String)
        case pan115
        case baidu
    }

    private let mark: Mark
    let title: String
    /// 只有一条时(错误 / 阻塞)才显示
    let subtitle: String?

    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.mark = .symbol(systemImage)
        self.title = title
        self.subtitle = subtitle
    }

    init(pan115Title title: String, subtitle: String? = nil) {
        self.mark = .pan115
        self.title = title
        self.subtitle = subtitle
    }

    init(baiduTitle title: String, subtitle: String? = nil) {
        self.mark = .baidu
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: Metrics.spacingS) {
            markView
                .padding(.bottom, Metrics.spacingXS)
            Text(title)
                .font(.title2.weight(.semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.top, Metrics.spacingXL)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .symbol(let name):
            Image(systemName: name)
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
        case .pan115:
            Pan115LogoMark(size: Metrics.onboardingLogoSize)
        case .baidu:
            BaiduPanLogoMark(size: Metrics.onboardingLogoSize)
        }
    }
}

/// 警告 / 错误提示:图标 + 文本,不只靠颜色。
struct OnboardingNotice: View {
    enum Style {
        case warning, error
    }

    let text: String
    let style: Style

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(style == .error ? Color.red : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 底部操作栏:进行中时主按钮换成转圈 + 文案,并禁止重复提交。
struct OnboardingActionBar: View {
    let primaryTitle: String
    let busyTitle: String
    let isBusy: Bool
    let canSubmit: Bool
    /// nil = 不显示取消(首次启动引导页)
    let onCancel: (() -> Void)?
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(busyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onCancel {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
            Button(action: onSubmit) {
                Text(primaryTitle)
                    .frame(minWidth: Metrics.onboardingPrimaryButtonMinWidth)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit || isBusy)
        }
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.bottom, Metrics.spacingXL)
        .padding(.top, Metrics.spacingS)
        .animation(.easeInOut(duration: Metrics.animationFast), value: isBusy)
    }
}
