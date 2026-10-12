import AppKit
import SwiftUI

/// 设置窗口的标签页。选中项存在 `@AppStorage` 里而不是 `@State`:
/// 播放器字幕菜单的「字幕外观…」要先把它切到「字幕」再打开设置窗口。
enum SettingsTab: String {
    case general
    case playback
    case subtitles
    case servers

    static let storageKey = "settings.selectedTab"
}

/// 设置窗口(⌘,)。四个标签页:
///
/// - **通用**:网络(自定义 User-Agent);
/// - **播放**:播放偏好(`PlaybackSettingsView`)—— 起播默认值与播放期开关;
/// - **字幕**:字幕外观(`SubtitleSettingsView`);
/// - **来源**:播放来源管理(增 / 改 / 删 / 切换 / 登录,`ServerListView`)。
///
/// 来源管理放在这里而不是主窗口:它是低频的配置动作,不属于日常浏览路径
/// (DesignTokens.swift「界面规则」)。
struct AppSettingsView: View {
    let container: AppContainer

    @AppStorage(SettingsTab.storageKey) private var selection = SettingsTab.general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView(credentials: container.credentials)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            PlaybackSettingsView(preferences: container.preferences)
                .tabItem { Label("播放", systemImage: "play.circle") }
                .tag(SettingsTab.playback)
            SubtitleSettingsView(store: container.subtitleStyles)
                .tabItem { Label("字幕", systemImage: "captions.bubble") }
                .tag(SettingsTab.subtitles)
            ServerListView(container: container)
                .tabItem { Label("来源", systemImage: "rectangle.stack.badge.plus") }
                .tag(SettingsTab.servers)
        }
        .frame(width: Metrics.settingsWindowWidth, height: Metrics.settingsWindowHeight)
    }
}

/// 通用:网络(自定义 User-Agent)+ 元数据刮削(TMDB token)。
private struct GeneralSettingsView: View {
    let credentials: CredentialStore

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

            MetadataScrapeSettingsView(credentials: credentials)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 元数据刮削:TMDB v4 Read Access Token 的输入。
///
/// ## 为什么让用户自己填 token
///
/// 内置一串等于把凭据编进二进制分发,而且所有人共用一份配额;
/// 自用场景下由用户填自己的(在 themoviedb.org 免费注册即得)才是对的形状。
/// token 存 `CredentialStore`,⛔ 不进 UserDefaults、不进仓库
/// (`docs/TMDB_API.md` §1)。
///
/// ## 为什么不做「测试连接」按钮
///
/// 那需要真发一次搜索请求,而刮削本来就是低频动作 —— 真要验证,
/// 浏览一次百度目录就会走到;多一个按钮只是多一个失败点。
private struct MetadataScrapeSettingsView: View {
    let credentials: CredentialStore

    /// 编辑中的值
    @State private var token = ""
    /// 磁盘上的现值(用于判断「有没有改」与「能不能清除」)
    @State private var savedToken = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case saved
        case error(String)
    }

    var body: some View {
        Section {
            SecureField(
                "Read Access Token",
                text: $token,
                prompt: Text("粘贴 TMDB 的 API Read Access Token")
            )
            .autocorrectionDisabled()

            HStack {
                statusLabel
                Spacer()
                Button("清除") {
                    Task { await clear() }
                }
                .disabled(savedToken.isEmpty && token.isEmpty)
                Button("保存") {
                    Task { await save() }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines) == savedToken)
            }
        } header: {
            Text("元数据刮削")
        } footer: {
            Text("给百度网盘来源刮封面与简介。填 TMDB 账号 API 设置页里的 v4「API Read Access Token」(一串 JWT),留空则不刮削。只写在本机凭据文件里,不进偏好设置、不进备份。")
        }
        .task { await load() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            if savedToken.isEmpty {
                Text("未配置,不刮削").foregroundStyle(.secondary)
            } else {
                Text("已配置").foregroundStyle(.secondary)
            }
        case .saved:
            Text("已保存").foregroundStyle(.secondary)
        case .error(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private func load() async {
        do {
            let existing = try await credentials.tmdbReadAccessToken() ?? ""
            token = existing
            savedToken = existing
            status = .idle
        } catch {
            // ⛔ 不静默吞:读不出来如实说,不假装「未配置」
            status = .error("读凭据文件失败")
        }
    }

    private func save() async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                // 留空 = 关闭刮削。删掉条目而不是存一个空串,读回来的语义更干净。
                try await credentials.deleteTMDBReadAccessToken()
            } else {
                try await credentials.saveTMDBReadAccessToken(trimmed)
            }
            token = trimmed
            savedToken = trimmed
            status = .saved
        } catch {
            status = .error("保存失败:凭据文件不可写")
        }
    }

    private func clear() async {
        do {
            try await credentials.deleteTMDBReadAccessToken()
            token = ""
            savedToken = ""
            status = .idle
        } catch {
            status = .error("清除失败:凭据文件不可写")
        }
    }
}

/// 播放偏好(`PlaybackPreferences`):起播默认值 + 播放期开关,全部服务器共用。
///
/// 起播类的偏好(倍速 / 音量 / 字幕)**下一次起播才生效**,不追溯正在播放的那一集:
/// 半途把画面上的倍速或音量改掉,比「我调了默认值,当前这集却跟着变」更难解释。
/// 三个开关是同一份状态,在播放窗口的「播放选项」菜单里改也一样。
private struct PlaybackSettingsView: View {
    @Bindable var preferences: PlaybackPreferences

    var body: some View {
        Form {
            Section {
                SettingsValueSlider(
                    title: "默认倍速", value: $preferences.defaultSpeed,
                    range: Metrics.speedRange, step: Metrics.speedStep,
                    text: PlayerViewModel.speedText(preferences.defaultSpeed))
                Picker("跳转步长", selection: $preferences.seekStep) {
                    ForEach(Metrics.seekStepOptions, id: \.self) { step in
                        Text("\(Int(step)) 秒").tag(step)
                    }
                }
                SettingsValueSlider(
                    title: "默认音量", value: $preferences.defaultVolume,
                    range: Metrics.volumeRange, step: Metrics.volumeStep,
                    text: "\(Int(preferences.defaultVolume.rounded()))")
            } header: {
                Text("起播")
            } footer: {
                Text("下一次开始播放时生效,不影响正在播放的视频。倍速还有一个更高的优先级:同一部剧本次运行里调过倍速,下一集沿用调过的那个值。跳转步长同时是方向键、控制栏前后跳按钮与菜单栏里的步长。")
            }

            Section {
                Picker("起播字幕", selection: $preferences.subtitleMode) {
                    ForEach(SubtitleMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("字幕")
            } footer: {
                Text(preferences.subtitleMode.detail + "只决定起播时自动选哪条轨,播放中手动选过之后以手动的为准。字幕外观在「字幕」页。")
            }

            Section {
                Picker("渲染器", selection: $preferences.renderBackendPolicy) {
                    ForEach(MPVRenderBackendPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            } header: {
                Text("色彩")
            } footer: {
                Text(preferences.renderBackendPolicy.detail + "下一次开始播放时生效。")
            }

            Section {
                Toggle("自动跳过片头", isOn: $preferences.autoSkipIntro)
                Toggle("自动播放下一集", isOn: $preferences.autoPlayNext)
                Toggle("窗口置顶", isOn: $preferences.floatsOnTop)
            } header: {
                Text("片头与连播")
            } footer: {
                Text("自动跳过片头默认关:片头标记不准时自动跳会直接吃掉正片开头,所以先给「跳过片头」按钮。这三项与播放窗口「播放选项」菜单里的是同一份状态。")
            }

            Section {
                HStack {
                    Text("下次开始播放时生效。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { preferences.reset() }
                        .disabled(preferences.isDefault)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 设置页的数值滑杆:标题在左,滑块与等宽数值在右(数值宽度固定,不随位数跳动)。
private struct SettingsValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Metrics.spacingS) {
                Slider(value: $value, in: range, step: step)
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
                SettingsValueSlider(
                    title: "字号", value: $store.style.scale,
                    range: SubtitleStyle.scaleRange, step: 0.05,
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
                    SettingsValueSlider(
                        title: "底框不透明度", value: $store.style.boxOpacity,
                        range: SubtitleStyle.boxOpacityRange, step: 0.05,
                        text: Self.percent(store.style.boxOpacity))
                } else {
                    SettingsValueSlider(
                        title: "描边粗细", value: $store.style.outlineSize,
                        range: SubtitleStyle.outlineRange, step: 0.25,
                        text: store.style.outlineSize == 0
                            ? "无" : store.style.outlineSize.formatted(.number.precision(.fractionLength(0...2))))
                }
            } header: {
                Text("边缘")
            } footer: {
                Text("亮画面上白字看不清时,换成「半透明底框」最稳。")
            }

            Section {
                SettingsValueSlider(
                    title: "垂直位置", value: $store.style.position,
                    range: SubtitleStyle.positionRange, step: 1,
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

    private static func color(_ color: SubtitleColor) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
