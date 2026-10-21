import AppKit
import SwiftUI

/// 设置窗口的标签页。选中项存在 `@AppStorage` 里而不是 `@State`:
/// 播放器字幕菜单的「字幕外观…」要先把它切到「字幕」再打开设置窗口。
enum SettingsTab: String {
    case general
    case playback
    case subtitles
    /// 弹幕:弹弹play 凭据 + 外观
    case danmaku
    case servers
    /// 被隐藏的条目(只在本机隐藏的那些,可恢复)
    case hidden
    /// 图片缓存(占用 / 上限 / 清空)
    case cache

    static let storageKey = "settings.selectedTab"
}

/// 设置窗口(⌘,)。七个标签页:
///
/// - **通用**:网络(自定义 User-Agent)+ 首页顶部推荐开关 + 元数据刮削(TMDB token);
/// - **播放**:播放偏好(`PlaybackSettingsView`)—— 起播默认值与播放期开关;
/// - **字幕**:字幕外观(`SubtitleSettingsView`)+ 在线字幕站(assrt)的 API 密钥;
/// - **弹幕**:弹弹play 的 AppId / AppSecret 与弹幕外观(`DanmakuSettingsView`);
/// - **来源**:播放来源管理(增 / 改 / 删 / 切换 / 登录,`ServerListView`);
/// - **已隐藏**:本机隐藏的条目(`HiddenItemsSettingsView`),逐条恢复;
/// - **缓存**:图片缓存的占用 / 上限 / 清空(`ImageCacheSettingsView`)。
///
/// 来源管理放在这里而不是主窗口:它是低频的配置动作,不属于日常浏览路径
/// (DesignTokens.swift「界面规则」)。缓存同理 —— 一年也点不了两次。
struct AppSettingsView: View {
    let container: AppContainer

    @AppStorage(SettingsTab.storageKey) private var selection = SettingsTab.general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView(
                credentials: container.credentials,
                homeAppearance: container.homeAppearance
            )
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            PlaybackSettingsView(preferences: container.preferences)
                .tabItem { Label("播放", systemImage: "play.circle") }
                .tag(SettingsTab.playback)
            SubtitleSettingsView(store: container.subtitleStyles, credentials: container.credentials)
                .tabItem { Label("字幕", systemImage: "captions.bubble") }
                .tag(SettingsTab.subtitles)
            DanmakuSettingsView(credentials: container.credentials, store: container.danmakuSettings)
                .tabItem { Label("弹幕", systemImage: "text.bubble") }
                .tag(SettingsTab.danmaku)
            ServerListView(container: container)
                .tabItem { Label("来源", systemImage: "rectangle.stack.badge.plus") }
                .tag(SettingsTab.servers)
            HiddenItemsSettingsView(store: container.hiddenItems)
                .tabItem { Label("已隐藏", systemImage: "eye.slash") }
                .tag(SettingsTab.hidden)
            ImageCacheSettingsView(
                preferences: container.imageCachePreferences,
                store: container.posters
            )
                .tabItem { Label("缓存", systemImage: "externaldrive") }
                .tag(SettingsTab.cache)
        }
        .frame(width: Metrics.settingsWindowWidth, height: Metrics.settingsWindowHeight)
    }
}

/// 通用:网络(自定义 User-Agent)+ 首页 + 元数据刮削(TMDB token)。
private struct GeneralSettingsView: View {
    let credentials: CredentialStore
    let homeAppearance: HomeAppearancePreferences

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

            HomeAppearanceSection(preferences: homeAppearance)

            MetadataScrapeSettingsView(credentials: credentials)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 首页:顶部那一大块随机推荐。
///
/// 关掉是**整块 hero 不显示**(首页直接从「我的媒体」开始),⛔ 不是退回去显示
/// 「继续观看 / 各库最新」那一张 —— 那是请求**失败**时的容错,不是用户的选择。
/// 关掉时也顺带不发那个推荐请求。
private struct HomeAppearanceSection: View {
    @Bindable var preferences: HomeAppearancePreferences

    var body: some View {
        Section {
            Toggle("显示首页推荐", isOn: $preferences.showsHeroRecommendations)
        } header: {
            Text("首页")
        } footer: {
            Text("首页顶部轮播的随机推荐(每次给不同的一批没看过的内容)。关掉后首页顶部不显示这一块,也不再请求推荐数据;「我的媒体」「继续观看」和各媒体库的「最新」不受影响。对所有服务器生效,改完回到首页立即生效。")
        }
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
struct SettingsValueSlider: View {
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
    let credentials: CredentialStore

    @State private var assrtToken = ""
    @State private var savedAssrtToken = ""
    @State private var tokenStatus: TokenStatus = .idle

    private enum TokenStatus: Equatable {
        case idle
        case saved
        case error(String)
    }

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
                SecureField(
                    "API 密钥", text: $assrtToken,
                    prompt: Text("assrt.net 用户面板里的 API 密钥"))
                    .autocorrectionDisabled()
                HStack {
                    tokenStatusLabel
                    Spacer()
                    Button("清除") { Task { await saveAssrtToken("") } }
                        .disabled(savedAssrtToken.isEmpty && trimmedAssrtToken.isEmpty)
                    Button("保存") { Task { await saveAssrtToken(trimmedAssrtToken) } }
                        .disabled(trimmedAssrtToken == savedAssrtToken)
                }
            } header: {
                Text("在线字幕(assrt)")
            } footer: {
                Text("播放页「字幕 › 搜索在线字幕…」用它搜索并下载字幕。到 assrt.net 注册后,在用户面板复制 API 密钥;只写在本机凭据文件里。")
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
        .task { await loadAssrtToken() }
    }

    private var trimmedAssrtToken: String {
        assrtToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var tokenStatusLabel: some View {
        switch tokenStatus {
        case .idle:
            Text(savedAssrtToken.isEmpty ? "未配置,不能搜索在线字幕" : "已配置")
                .foregroundStyle(.secondary)
        case .saved:
            Text("已保存").foregroundStyle(.secondary)
        case .error(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private func loadAssrtToken() async {
        do {
            let token = try await credentials.assrtToken() ?? ""
            assrtToken = token
            savedAssrtToken = token
            tokenStatus = .idle
        } catch {
            // ⛔ 不静默吞:读不出来如实说,不假装「未配置」
            tokenStatus = .error("读凭据文件失败")
        }
    }

    /// 空串 = 清除。与弹幕凭据同一套做法(保存 / 清除共用一条通路)。
    private func saveAssrtToken(_ token: String) async {
        do {
            if token.isEmpty {
                try await credentials.deleteAssrtToken()
            } else {
                try await credentials.saveAssrtToken(token)
            }
            assrtToken = token
            savedAssrtToken = token
            tokenStatus = .saved
        } catch {
            tokenStatus = .error("保存失败")
        }
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

/// 缓存:图片(海报 / 背景图 / 剧照 / 网盘封面)的磁盘占用、上限与清空。
///
/// ## 为什么只放图片缓存
///
/// 这里只摆**随时可以丢掉的派生数据**。接口响应缓存(`EmbyResponseCache`)不进这页:
/// 它按服务器隔离、跟随登录态整片作废,清掉之后用户感知不到任何「腾出了空间」,
/// 却要白等一轮接口往返(见 `Core/Cache/EmbyResponseCache.swift`)。
///
/// ## 数字从哪来
///
/// 占用**现扫磁盘**(`PosterImageStore.diskUsage()`),不读缓存层自己的字节簿记 ——
/// 簿记只覆盖 App 自己的写入,手删目录 / 系统清理之后就偏了,而这一页正是要「准」的地方。
/// 上限一经改动立即生效并立刻淘汰,不需要重启或等下一次写盘。
private struct ImageCacheSettingsView: View {
    @Bindable var preferences: ImageCachePreferences
    let store: PosterImageStore

    @State private var usage: PosterDiskCache.Usage?
    @State private var isBusy = false
    @State private var confirmsClear = false

    var body: some View {
        Form {
            Section {
                LabeledContent("已用空间") {
                    Text(usageText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Picker("上限", selection: $preferences.byteLimitMB) {
                    ForEach(ImageCachePreferences.byteLimitOptionsMB, id: \.self) { megabytes in
                        Text(Self.sizeText(megabytes * 1024 * 1024)).tag(megabytes)
                    }
                }
                HStack {
                    Text("调小上限会立刻淘汰最久未用的图片。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空图片缓存") { confirmsClear = true }
                        .disabled(isBusy || (usage?.fileCount ?? 0) == 0)
                }
            } header: {
                Text("图片缓存")
            } footer: {
                Text("海报、背景图、分集剧照与网盘封面的本地副本,存在 App 的缓存目录里,超出上限按最久未用淘汰。清空只删本机副本:服务器上的图、观看记录与进度都不受影响,之后浏览时按需重新下载。")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await refreshUsage() }
        .onChange(of: preferences.byteLimitMB) { _, newValue in
            Task {
                await store.setDiskByteLimit(newValue * 1024 * 1024)
                await refreshUsage()
            }
        }
        .alert("清空图片缓存?", isPresented: $confirmsClear) {
            Button("清空", role: .destructive) { Task { await clear() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删掉本机 \(usageText) 的图片副本。服务器上的图不受影响,之后浏览时重新下载;正在显示的图也不会突然消失。")
        }
    }

    private var usageText: String {
        guard let usage else { return "统计中…" }
        // 一条都没有时不能落进 ByteCountFormatter:它对 0 字节给的是「Zero KB」
        guard usage.fileCount > 0 else { return Self.sizeText(0) }
        return "\(Self.sizeText(usage.bytes))(\(usage.fileCount.formatted()) 张)"
    }

    private func refreshUsage() async {
        usage = await store.diskUsage()
    }

    private func clear() async {
        isBusy = true
        await store.clearAll()
        await refreshUsage()
        isBusy = false
    }

    /// 二进制单位(1024)。与档位数字同一套进制:256 MB 就显示「256 MB」,
    /// ⛔ 不用十进制单位把它显示成「268.4 MB」。
    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// 已隐藏:本机隐藏的条目,逐条恢复。
///
/// ## 这里只有「只隐藏」的那些
///
/// 连网盘一起删掉的条目⛔ 不进这个列表 —— 文件已经不在网盘,恢复不出任何东西
/// (`BaiduPanSourceViewModel.delete` 的注释)。所以这个列表的每一条都是
/// **网盘上还在、只是不想看见**的条目。
///
/// ⚠️ 恢复只把**条目**放回列表,**不还原观看记录**:隐藏时本地进度已经清掉了
/// (这也是「继续观看」里那张卡消失的原因)。⛔ 按钮别写成「撤销」——
/// 那会让人以为进度也能一起回来。
private struct HiddenItemsSettingsView: View {
    let store: HiddenItemsStore

    @State private var items: [HiddenItemsStore.Item] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("没有隐藏的条目", systemImage: "eye.slash")
                } description: {
                    Text("在百度网盘片库里右键一张卡片选「删除…」、且不勾选"
                        + "「同时删除网盘里的文件」时,条目会记在这里。"
                        + "隐藏时本地观看记录会一并清掉,恢复后进度不会回来。")
                }
            } else {
                List(items) { item in
                    HStack(spacing: Metrics.spacingM) {
                        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                            Text(item.title)
                                .lineLimit(2)
                            Text(Self.dateText(item.hiddenAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复") { Task { await restore(item) } }
                            .help("把条目放回片库列表。隐藏时清掉的本机观看记录不会恢复。")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await reload() }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() async {
        items = await store.all()
    }

    private func restore(_ item: HiddenItemsStore.Item) async {
        do {
            try await store.restore(item.ref)
            await reload()
        } catch {
            errorMessage = "恢复失败:\(error)"
        }
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute())
    }
}
