import AppKit
import SwiftUI

/// 手动输入片头 / 片尾的表单。输入格式见 `PlayerTime.parse`;留空 = 不标这一格,
/// 只有片头起点例外:留空按 00:00 计(见 `ManualMarkers.asPlaybackMarkers`)。
///
/// 保存原始值:逻辑校验(片头终点晚于起点)只提示不拦保存,中间态要能存下来。
///
/// ⛔ 表体不要读 `viewModel.positionSeconds`(每 0.2s 变一次);「用当前位置」只在点击时读。
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
                    detail: "播放到片头区间时出现「跳过片头」,跳过即跳到终点。起点留空按 00:00 计。"
                ) {
                    fieldRow("起点", text: $introStartText, placeholder: "留空 = 00:00")
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
        // 播放页的 `.environment(\.colorScheme, .dark)` 不改 sheet 窗口底色(会白字浅底);
        // 必须用 `preferredColorScheme` 把 sheet 窗口本身设成深色
        .preferredColorScheme(.dark)
    }

    /// 写死的不透明深色兜底:`preferredColorScheme` 没落到窗口上时也不会白字白底。
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

    private func fieldRow(
        _ title: String,
        text: Binding<String>,
        placeholder: String = "留空 = 不标"
    ) -> some View {
        HStack(spacing: Metrics.spacingM) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            TextField(placeholder, text: text)
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

    /// 空白 = 不标;非空则必须能解析。
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

    /// 格式错误优先;片头只填起点 / 顺序不对只提醒不拦保存。
    private var hintText: String? {
        if !allFieldsValid { return "时间格式不对:用 hh:mm:ss、mm:ss 或秒数。" }
        let start = introStart.seconds
        let end = introEnd.seconds
        if start != nil, end == nil {
            return "片头只填了起点:没有终点就不知道跳到哪,不会跳过片头。"
        }
        if let end, end <= (start ?? 0) {
            return "片头终点要晚于起点(起点留空按 00:00 计),否则不会跳过片头。"
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
