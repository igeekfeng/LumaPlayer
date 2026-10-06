import AppKit
import SwiftUI

/// 设置窗口的标签页。选中项存在 `@AppStorage` 里而不是 `@State`:
/// 播放器字幕菜单的「字幕外观…」要先把它切到「字幕」再打开设置窗口。
enum SettingsTab: String {
    case general
    case subtitles
    case servers

    static let storageKey = "settings.selectedTab"
}

/// 设置窗口(⌘,)。三个标签页:
///
/// - **通用**:网络(自定义 User-Agent);
/// - **字幕**:字幕外观(`SubtitleSettingsView`);
/// - **服务器**:服务器管理(增 / 改 / 删 / 切换 / 登录,`ServerListView`)。
///
/// 服务器管理放在这里而不是主窗口:它是低频的配置动作,不属于日常浏览路径
/// (UI_DESIGN.md 3.1)。
struct AppSettingsView: View {
    let container: AppContainer

    @AppStorage(SettingsTab.storageKey) private var selection = SettingsTab.general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SubtitleSettingsView(store: container.subtitleStyles)
                .tabItem { Label("字幕", systemImage: "captions.bubble") }
                .tag(SettingsTab.subtitles)
            ServerListView(container: container)
                .tabItem { Label("服务器", systemImage: "server.rack") }
                .tag(SettingsTab.servers)
        }
        .frame(width: Metrics.settingsWindowWidth, height: Metrics.settingsWindowHeight)
    }
}

/// 通用:网络(自定义 User-Agent)。
private struct GeneralSettingsView: View {
    @AppStorage(ClientUserAgent.customKey) private var customUserAgent = ""

    var body: some View {
        Form {
            Section {
                TextField(
                    "自定义 User-Agent",
                    text: $customUserAgent,
                    prompt: Text("留空使用默认 LumaPlayer/版本")
                )
                .autocorrectionDisabled()
            } header: {
                Text("网络")
            } footer: {
                Text("部分服务器只放行白名单播放器,按 User-Agent 拒绝其余客户端拉流(表现为能登录浏览、播放报无法识别的文件格式)。填写后对所有服务器的请求与播放生效,改完立即生效。请只在确有需要时使用,并自行承担服务器方的处置风险。")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 字幕外观(`SubtitleStyle`):全部服务器共用,改完对正在播放的视频立即生效。
///
/// ⛔ 不做「预览字幕」:SwiftUI 画出来的样子和 libass 的渲染(描边算法、字体回退、
/// 按窗口缩放)对不上,一个不准的预览比没有更误导。正在播放的画面就是准确的预览。
private struct SubtitleSettingsView: View {
    @Bindable var store: SubtitleStyleStore

    var body: some View {
        Form {
            Section("文字") {
                valueSlider(
                    "字号", value: $store.style.scale, in: SubtitleStyle.scaleRange, step: 0.05,
                    text: Self.percent(store.style.scale))
                LabeledContent("颜色") { colorRow }
                Toggle("粗体", isOn: $store.style.isBold)
            }

            Section {
                Picker("效果", selection: $store.style.edge) {
                    Text("描边").tag(SubtitleStyle.Edge.outline)
                    Text("描边 + 阴影").tag(SubtitleStyle.Edge.shadow)
                    Text("半透明底框").tag(SubtitleStyle.Edge.box)
                }
                .pickerStyle(.segmented)
                if store.style.edge == .box {
                    valueSlider(
                        "底框不透明度", value: $store.style.boxOpacity,
                        in: SubtitleStyle.boxOpacityRange, step: 0.05,
                        text: Self.percent(store.style.boxOpacity))
                } else {
                    valueSlider(
                        "描边粗细", value: $store.style.outlineSize,
                        in: SubtitleStyle.outlineRange, step: 0.25,
                        text: store.style.outlineSize == 0
                            ? "无" : store.style.outlineSize.formatted(.number.precision(.fractionLength(0...2))))
                }
            } header: {
                Text("边缘")
            } footer: {
                Text("亮画面上白字看不清时,换成「半透明底框」最稳。")
            }

            Section {
                valueSlider(
                    "垂直位置", value: $store.style.position, in: SubtitleStyle.positionRange, step: 1,
                    text: store.style.position == SubtitleStyle.positionRange.upperBound
                        ? "底部" : "上移 \(Int((SubtitleStyle.positionRange.upperBound - store.style.position).rounded()))%")
            } header: {
                Text("位置")
            } footer: {
                Text("百分比是相对画面高度。")
            }

            Section {
                Toggle("对 ASS 特效字幕也套用以上样式", isOn: $store.style.overridesASS)
            } header: {
                Text("ASS 字幕")
            } footer: {
                Text("ASS 字幕自带颜色、字体与排版,默认只跟随这里的字号。打开后颜色、描边、位置也会强制覆盖,可能弄乱招牌、歌词这类特效排版;只建议在字幕组样式实在看不清时使用。")
            }

            Section {
                HStack {
                    Text("修改对正在播放的视频立即生效。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { store.reset() }
                        .disabled(store.style == .default)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 预设色 + 系统取色器。预设是一排色块,选中的那个带描边与 `.isSelected`(VoiceOver 读得出)。
    private var colorRow: some View {
        HStack(spacing: Metrics.spacingS) {
            ForEach(SubtitleColor.presets, id: \.color) { preset in
                let isSelected = store.style.textColor == preset.color
                Button { store.style.textColor = preset.color } label: {
                    Circle()
                        .fill(Self.color(preset.color))
                        .overlay(Circle().strokeBorder(.separator))
                        .padding(Metrics.spacingXS / 2)
                        .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: Metrics.colorSwatchSize, height: Metrics.colorSwatchSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            ColorPicker("自定义颜色", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .help("自定义颜色")
        }
    }

    /// `Color` ↔ `SubtitleColor`。取色器给的颜色可能不在 sRGB(比如 Display P3),
    /// 转不过去时保持原值不动 —— 宁可这一下没变,也不写一个算错的颜色进偏好。
    private var customColor: Binding<Color> {
        Binding(
            get: { Self.color(store.style.textColor) },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                store.style.textColor = SubtitleColor(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent)
                ).clamped
            }
        )
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: Metrics.spacingS) {
                Slider(value: value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(text)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Metrics.settingsValueWidth, alignment: .trailing)
            }
        }
    }

    private static func color(_ color: SubtitleColor) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
