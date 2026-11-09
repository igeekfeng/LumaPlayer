import SwiftUI

/// 手动输入片头 / 片尾的表单。输入格式见 `PlayerTime.parse`;留空 = 不标这一格,
/// 只有片头起点例外:留空按 00:00 计(见 `ManualMarkers.asPlaybackMarkers`)。
///
/// 保存原始值:逻辑校验(片头终点晚于起点)只提示不拦保存,中间态要能存下来。
///
/// ⛔ 表体不要读 `viewModel.positionSeconds`(每 0.2s 变一次);「用当前位置」只在点击时读。
struct PlayerMarkersEditor: View {
    /// 片尾的两种表达。默认「结尾前」:同一部剧共用一份标注,每集长度不同,
    /// 固定时刻放到别的集就会切早 / 切晚。
    enum CreditsMode: String, CaseIterable {
        case fromEnd = "结尾前"
        case fixed = "固定时刻"
    }

    let viewModel: PlayerViewModel
    var onClose: () -> Void

    @State private var introStartText: String
    @State private var introEndText: String
    @State private var creditsMode: CreditsMode = .fromEnd
    @State private var creditsText: String

    init(viewModel: PlayerViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        let values = viewModel.manualMarkerValues
        _introStartText = State(initialValue: PlayerTime.markerText(values?.introStart))
        _introEndText = State(initialValue: PlayerTime.markerText(values?.introEnd))
        let reference = values?.creditsReference
        _creditsMode = State(
            initialValue: reference?.isBeforeEnd == true ? .fromEnd : (reference == nil ? .fromEnd : .fixed))
        _creditsText = State(initialValue: Self.creditsText(for: reference))
    }

    var body: some View {
        PlayerModalCard(
            title: "片头与片尾",
            systemImage: "flag.checkered",
            subtitle: "同一部剧的每一集共用这份标记。输入 hh:mm:ss、mm:ss 或秒数,留空表示不标。",
            width: 460,
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: 0) {
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
                    detail: "到这里自动换下一集;提前 10 秒出现「下一集」并开始倒计时。"
                ) {
                    VStack(alignment: .leading, spacing: Metrics.spacingS) {
                        Picker("片尾方式", selection: $creditsMode) {
                            ForEach(CreditsMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        fieldRow(
                            creditsMode == .fromEnd ? "距结尾" : "时刻",
                            text: $creditsText,
                            placeholder: "留空 = 不标",
                            useCurrentPosition: creditsPosition
                        )
                        .onChange(of: creditsMode) { _, _ in
                            // 单位变了,原来的数字不再代表同一含义,清掉避免误存
                            creditsText = ""
                        }
                    }
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
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - 版块

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
        placeholder: String = "留空 = 不标",
        useCurrentPosition: (() -> Double)? = nil
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
                let value = useCurrentPosition?() ?? viewModel.positionSeconds
                text.wrappedValue = PlayerTime.markerText(value)
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
    private var credits: Field { Field(text: creditsText) }

    private var allFieldsValid: Bool {
        introStart.isValid && introEnd.isValid && credits.isValid
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
        if creditsMode == .fromEnd, viewModel.durationSeconds <= 0 {
            return "时长未知,「结尾前」换算不出来;可改用「固定时刻」。"
        }
        return nil
    }

    private func save() {
        guard allFieldsValid else { return }
        viewModel.setManualMarkers(
            introStart: introStart.seconds,
            introEnd: introEnd.seconds,
            creditsStart: creditsMode == .fixed ? credits.seconds : nil,
            creditsLead: creditsMode == .fromEnd ? credits.seconds : nil)
        onClose()
    }

    // MARK: - 片尾回显 / 取值

    private static func creditsText(for reference: PlaybackMarkers.Credits?) -> String {
        guard let reference else { return "" }
        switch reference {
        case .at(let start): return PlayerTime.markerText(start)
        case .beforeEnd(let lead): return PlayerTime.markerText(lead)
        }
    }

    /// 「用当前位置」取值:结尾前模式取距结尾时长,固定时刻模式取当前时刻。
    private func creditsPosition() -> Double {
        if creditsMode == .fromEnd, viewModel.durationSeconds > 0 {
            return max(0, viewModel.durationSeconds - viewModel.positionSeconds)
        }
        return viewModel.positionSeconds
    }
}
