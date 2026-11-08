import SwiftUI

/// 播放页里的模态卡片:macOS 窗口观感(材质 + 圆角 + 描边 + 红绿灯关闭),内容区由各弹窗自己填。
///
/// ⛔ 不用系统 `.sheet`:它的遮罩颜色不可控,点窗口空白处也不会关闭。
/// 呈现交给 `PlayerModalOverlay`(透明可点区域 + 居中),这里只管卡片本身。
struct PlayerModalCard<Content: View>: View {
    let title: String
    let systemImage: String
    let subtitle: String
    /// 整张卡片的宽度:⛔ 必须约束在最外层,放在内容里会被 `maxWidth: .infinity` 的标题撑成整窗宽
    let width: CGFloat
    var onClose: () -> Void
    @ViewBuilder var content: Content

    @State private var isHoveringClose = false

    private let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
                .frame(maxWidth: .infinity)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.bottom, Metrics.spacingXL)
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        // 视频亮度不可控:材质下面压一层深色,保证文字始终读得出来
        .background(.regularMaterial, in: shape)
        .background(Color.black.opacity(0.32), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    /// 居中标题 + 左上角红绿灯,与 macOS 窗口标题栏一致。
    private var titleBar: some View {
        ZStack {
            HStack(spacing: Metrics.spacingXS) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
            }
            HStack {
                closeButton
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Metrics.spacingM)
        .frame(height: 34)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            ZStack {
                Circle()
                    .fill(Color(red: 1, green: 0.37, blue: 0.34))
                if isHoveringClose {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.7))
                }
            }
            .frame(width: 12, height: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringClose = $0 }
        .help("关闭")
        .accessibilityLabel("关闭")
    }
}

/// 模态浮层:全窗口透明区域只负责「点旁边关闭」,卡片居中且不挡周围画面。
/// 挂在播放页 `onKeyPress` 链的外层,弹窗内打字不会被播放快捷键吃掉(见 `PlayerWindowView`)。
struct PlayerModalOverlay<Content: View>: View {
    var onClose: () -> Void
    @ViewBuilder var content: Content

    /// 接管窗口焦点:播放页根视图是 `.focusable()`,不抢过来时按键会派给播放快捷键
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 播放根视图是 `.focusable()`:不把焦点抢到浮层这一支,按键会派给播放快捷键
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        // ⛔ 不做进出动画:浮层在主窗口视图树内,材质(NSVisualEffectView)+ 缩放/阴影的逐帧
        // 重采样会与 gpu-next 的视频渲染争 GPU,关闭时表现为视频卡顿。条件视图一次性移除即可。
        // 原来系统 sheet 自带 Esc/cancelAction 关闭,改浮层后自己接管
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }
}
