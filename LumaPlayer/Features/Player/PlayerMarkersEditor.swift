import AppKit
import SwiftUI

/// 手动输入片头 / 片尾的表单(播放页「播放选项 › 片头片尾 › 手动输入…」打开)。
///
/// 三格:片头起点 / 片头终点 / 片尾起点。每格是文本框 + 「用当前位置」按钮,
/// 输入接受 `hh:mm:ss` / `mm:ss` / 秒数(见 `PlayerTime.parse`),留空 = 不标这一格。
///
/// 保存的是**原始值**,逻辑校验(片头两端齐全、终点晚于起点)只在提示里说,
/// 不拦保存 —— 用户可能先把起点标好、过一会儿再标终点,中间态要能存下来。
///
/// ⚠️ 表体⛔ **不要**读 `viewModel.positionSeconds`:它是每 0.2s 变一次的值。
/// 「用当前位置」按钮在**点击时**才去读(见 `fieldRow` 的 action),不是渲染依赖。
struct PlayerMarkersEditor: View {
    let viewModel: PlayerViewModel
    var onClose: () -> Void

    @State private var introStartText: String
    @State private var introEndText: String
    @State private var creditsStartText: String

    init(viewModel: PlayerViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        let values = viewModel.manualMarkerValues
        _introStartText = State(initialValue: PlayerTime.markerText(values?.introStart))
        _introEndText = State(initialValue: PlayerTime.markerText(values?.introEnd))
        _creditsStartText = State(initialValue: PlayerTime.markerText(values?.creditsStart))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(Metrics.spacingXL)

            Divider()

            VStack(alignment: .leading, spacing: Metrics.spacingL) {
                section(
                    "片头",
                    detail: "播放到片头区间时出现「跳过片头」,跳过即跳到终点。"
                ) {
                    fieldRow("起点", text: $introStartText)
                    fieldRow("终点", text: $introEndText)
                }
                section(
                    "片尾",
                    detail: "播放到这里就提示「下一集」。"
                ) {
                    fieldRow("开始", text: $creditsStartText)
                }
            }
            .padding(Metrics.spacingXL)

            if let hint = hintText {
                Label(hint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.spacingXL)
                    .padding(.bottom, Metrics.spacingM)
            }

            Divider()

            footer
                .padding(Metrics.spacingXL)
        }
        .frame(width: 460)
        .background(Self.background)
        // 播放页用 `.environment(\.colorScheme, .dark)` 强制深色,那只改**内容**配色,
        // ⛔ 不改 sheet 这个新窗口的底色 —— 结果是文字全白、窗口还是浅色,整个面板看不见
        // (2026-10-12 用户实测)。`preferredColorScheme` 才会把 sheet 窗口本身也设成深色,
        // 让系统控件(输入框、按钮、分隔线)与底色一致。
        .preferredColorScheme(.dark)
    }

    /// 面板底色。
    ///
    /// 深色是**写死的**、不跟随系统外观:播放页固定深色,sheet 却在浅色系统下会拿到浅底,
    /// 光靠 `preferredColorScheme` 万一没落到窗口上就是白字白底。铺一层不透明的深色兜底,
    /// 两种情况下都可读。
    private static let background = Color(nsColor: NSColor(white: 0.12, alpha: 1))


    // MARK: - 版块

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            Image(systemName: "flag.checkered")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text("片头与片尾")
                    .font(.headline)
                Text("同一部剧的每一集共用这份标记。输入 hh:mm:ss、mm:ss 或秒数,留空表示不标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(
        _ title: String,
        detail: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                Text(title)
                    .font(.subheadline)
                    .bold()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: Metrics.spacingM) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            TextField("留空 = 不标", text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 120)
            Button("用当前位置") {
                text.wrappedValue = PlayerTime.markerText(viewModel.positionSeconds)
            }
            .controlSize(.small)
            .help("把当前播放位置填入这一格")
            Spacer(minLength: 0)
        }
        .padding(.leading, Metrics.spacingL)
    }

    private var footer: some View {
        HStack {
            Button("清除", role: .destructive) {
                viewModel.clearManualMarkers()
                onClose()
            }
            .disabled(!viewModel.hasManualMarkers)
            Spacer()
            Button("取消") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!allFieldsValid)
        }
    }

    // MARK: - 校验

    /// 一个输入格:空白 = 不标;非空则必须能解析出来。
    private struct Field {
        let text: String
        private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
        var isBlank: Bool { trimmed.isEmpty }
        var seconds: Double? { PlayerTime.parse(trimmed) }
        var isValid: Bool { isBlank || seconds != nil }
    }

    private var introStart: Field { Field(text: introStartText) }
    private var introEnd: Field { Field(text: introEndText) }
    private var creditsStart: Field { Field(text: creditsStartText) }

    private var allFieldsValid: Bool {
        introStart.isValid && introEnd.isValid && creditsStart.isValid
    }

    /// 提示:格式错误优先说错;否则说片头填得不完整 / 顺序不对(不拦保存,只提醒「这么填不生效」)。
    private var hintText: String? {
        if !allFieldsValid { return "时间格式不对:用 hh:mm:ss、mm:ss 或秒数。" }
        let start = introStart.seconds
        let end = introEnd.seconds
        if (start == nil) != (end == nil) {
            return "片头需要起点与终点都填才会跳过片头。"
        }
        if let start, let end, end <= start {
            return "片头终点要晚于起点,否则不会跳过片头。"
        }
        return nil
    }

    private func save() {
        guard allFieldsValid else { return }
        viewModel.setManualMarkers(
            introStart: introStart.seconds,
            introEnd: introEnd.seconds,
            creditsStart: creditsStart.seconds)
        onClose()
    }
}
