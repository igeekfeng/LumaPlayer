import SwiftUI

// 表单外壳:添加服务器 / 重新登录 / 编辑服务器共用。

/// 表单顶部:图标 + 标题 + 一行说明。
struct OnboardingFormHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Metrics.spacingS) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, Metrics.spacingXS)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.top, Metrics.spacingXL)
    }
}

/// 表单里的警告 / 错误提示。图标 + 文本,不只靠颜色(DesignTokens.swift「界面规则」)。
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
    /// nil = 不显示取消(首次启动的引导页没有可返回的地方)
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
