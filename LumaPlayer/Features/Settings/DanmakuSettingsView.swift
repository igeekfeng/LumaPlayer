import SwiftUI

/// 设置 › 弹幕:弹幕来源(官方弹弹play + 自建兼容服务)+ 弹幕外观。
///
/// 弹弹play 要求 AppSecret 不硬编码进客户端,本项目没有服务端可代签名,由用户自填
/// (`docs/DANDANPLAY_API.md` §1)。⛔ 凭据与自建服务地址(含令牌)进 `CredentialStore`(0600、不进备份),
/// 不进 UserDefaults、不进仓库。
struct DanmakuSettingsView: View {
    let credentials: CredentialStore
    let danmaku: DanmakuService
    @Bindable var store: DanmakuSettingsStore

    var body: some View {
        Form {
            DanmakuSourcesSection(danmaku: danmaku)
            DandanplayCredentialsSection(credentials: credentials)

            Section {
                Toggle("播放时自动加载弹幕", isOn: $store.settings.isEnabled)
                Toggle("用文件指纹提高匹配准确度", isOn: $store.settings.usesFileFingerprint)
            } footer: {
                Text("关掉自动加载后,播放页默认不显示弹幕,可随时在播放页「弹幕」菜单或按 D 打开。\n"
                    + "文件指纹 = 起播时对直连流多读 16 MB 算 MD5。它是「同一份文件」的硬证据,"
                    + "准确度明显高于只按文件名猜;代价是多一次 16 MB 读取。"
                    + "限速或按流量计费的服务器可以关掉,关掉后只按文件名匹配。")
            }

            Section("外观") {
                SettingsValueSlider(
                    title: "不透明度", value: $store.settings.opacity,
                    range: DanmakuDisplaySettings.opacityRange, step: 0.05,
                    text: "\(Int((store.settings.opacity * 100).rounded()))%")
                SettingsValueSlider(
                    title: "字号", value: $store.settings.fontSize,
                    range: DanmakuDisplaySettings.fontSizeRange, step: 1,
                    text: "\(Int(store.settings.fontSize))")
                SettingsValueSlider(
                    title: "滚动时长", value: $store.settings.scrollDuration,
                    range: DanmakuDisplaySettings.scrollDurationRange, step: 0.5,
                    text: "\(store.settings.scrollDuration.formatted(.number.precision(.fractionLength(0...1)))) 秒")
                Picker("显示区域", selection: $store.settings.displayArea) {
                    ForEach(DanmakuDisplaySettings.displayAreaChoices, id: \.self) { area in
                        Text(area == 1 ? "全屏" : "\(Int(area * 100))%").tag(area)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("滚动弹幕", isOn: $store.settings.showsScroll)
                Toggle("顶部弹幕", isOn: $store.settings.showsTop)
                Toggle("底部弹幕", isOn: $store.settings.showsBottom)
            } header: {
                Text("类型")
            } footer: {
                Text("字号以 1080p 画面为基准,随窗口大小等比缩放。弹幕太密时放不下的会直接略过,不会叠在一起。")
            }

            Section {
                Button("恢复默认外观") { store.reset() }
            }
        }
        .formStyle(.grouped)
    }
}

/// 官方弹弹play 应用凭据输入:保存才落盘、两项都留空 = 清除、读不出来如实报错。
/// ⛔ 不做「测试连接」:接口有滥用检测,验证留给第一次播放的真实请求。
private struct DandanplayCredentialsSection: View {
    let credentials: CredentialStore

    @State private var appID = ""
    @State private var appSecret = ""
    @State private var saved = DandanplayCredentials(appID: "", appSecret: "")
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case saved
        case error(String)
    }

    private var edited: DandanplayCredentials {
        DandanplayCredentials(
            appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
            appSecret: appSecret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Section {
            TextField("AppId", text: $appID, prompt: Text("弹弹play 开放平台的 AppId"))
                .autocorrectionDisabled()
            SecureField("AppSecret", text: $appSecret, prompt: Text("对应的 AppSecret"))
                .autocorrectionDisabled()
            HStack {
                statusLabel
                Spacer()
                Button("清除") { Task { await clear() } }
                    .disabled(saved.isEmpty && edited.isEmpty)
                Button("保存") { Task { await save() } }
                    .disabled(edited == saved || edited.appID.isEmpty != edited.appSecret.isEmpty)
            }
        } header: {
            Text("弹弹play 官方")
        } footer: {
            Text("在 dev.dandanplay.com 注册开发者、创建应用并通过审核后获得。只用自建服务可以不填。"
                + "只写在本机凭据文件里;AppSecret 只用于在本机计算请求签名,不会被发送出去。")
        }
        .task { await load() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            Text(saved.isEmpty ? "未填写" : "已填写").foregroundStyle(.secondary)
        case .saved:
            Text("已保存").foregroundStyle(.secondary)
        case .error(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private func load() async {
        do {
            let existing = try await credentials.dandanplayCredentials()
                ?? DandanplayCredentials(appID: "", appSecret: "")
            appID = existing.appID
            appSecret = existing.appSecret
            saved = existing
            status = .idle
        } catch {
            // ⛔ 不静默吞:读不出来如实说,不假装「未配置」
            status = .error("读凭据文件失败")
        }
    }

    private func save() async {
        let value = edited
        do {
            if value.isEmpty {
                try await credentials.deleteDandanplayCredentials()
            } else {
                try await credentials.saveDandanplayCredentials(value)
            }
            appID = value.appID
            appSecret = value.appSecret
            saved = value
            status = .saved
        } catch {
            status = .error("保存失败:凭据文件不可写")
        }
    }

    private func clear() async {
        do {
            try await credentials.deleteDandanplayCredentials()
            appID = ""
            appSecret = ""
            saved = DandanplayCredentials(appID: "", appSecret: "")
            status = .idle
        } catch {
            status = .error("清除失败:凭据文件不可写")
        }
    }
}

/// 默认来源 + 自建弹幕服务列表。改动立即落盘;删掉的服务连同它的匹配记录一起清(`DanmakuService.saveSourceSettings`)。
/// ⛔ 不做「测试连接」(理由同上),地址只在本地校验能不能解析。
private struct DanmakuSourcesSection: View {
    let danmaku: DanmakuService

    @State private var settings = DanmakuSourceSettings()
    @State private var newName = ""
    @State private var newAddress = ""
    @State private var error: String?
    @State private var isLoaded = false

    private var trimmedAddress: String { newAddress.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var addressIsValid: Bool { DandanplayBase(urlString: trimmedAddress) != nil }

    var body: some View {
        Section {
            Picker("默认来源", selection: Binding(
                get: { settings.defaultSource.id },
                set: { id in
                    var updated = settings
                    updated.defaultSourceID = id == DanmakuSource.officialID ? nil : id
                    Task { await save(updated) }
                }
            )) {
                ForEach(settings.sources) { source in
                    Text(source.isOfficial ? "弹弹play(官方)" : source.name).tag(source.id)
                }
            }
            .disabled(!isLoaded)
            if let error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("弹幕来源")
        } footer: {
            Text("播放时默认用这个来源匹配弹幕;播放页「弹幕」面板里可以临时为某一集换来源。"
                + "各来源的匹配记录分开保存,互不影响。")
        }

        Section {
            ForEach(settings.customSources) { source in
                HStack {
                    VStack(alignment: .leading) {
                        Text(source.name)
                        Text(Self.maskedAddress(source.baseURL))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("删除", role: .destructive) {
                        var updated = settings
                        updated.customSources.removeAll { $0.id == source.id }
                        Task { await save(updated) }
                    }
                }
            }
            TextField("名称", text: $newName, prompt: Text("如 danmu_api"))
                .autocorrectionDisabled()
            TextField("地址", text: $newAddress, prompt: Text("http://127.0.0.1:9321/令牌"))
                .autocorrectionDisabled()
            HStack {
                if !trimmedAddress.isEmpty, !addressIsValid {
                    Text("地址要以 http:// 或 https:// 开头,不带 ? 与 #").foregroundStyle(.red)
                }
                Spacer()
                Button("添加") { Task { await add() } }
                    .disabled(!isLoaded || trimmedName.isEmpty || !addressIsValid)
            }
        } header: {
            Text("自建弹幕服务")
        } footer: {
            Text("弹弹play 兼容服务(如 danmu_api)不需要 AppId / AppSecret。"
                + "这类服务的令牌写在 URL 路径里,地址要带上,如 http://127.0.0.1:9321/87654321。")
        }
        .task { await load() }
    }

    /// 列表里只露出协议与主机,路径(令牌)打码。
    static func maskedAddress(_ address: String) -> String {
        guard let base = DandanplayBase(urlString: address) else { return "地址无法解析" }
        let port = base.port.map { ":\($0)" } ?? ""
        return "\(base.scheme)://\(base.host)\(port)" + (base.pathPrefix.isEmpty ? "" : "/••••")
    }

    private func load() async {
        do {
            settings = try await danmaku.sourceSettings()
            isLoaded = true
            error = nil
        } catch {
            // ⛔ 不当成「没有自建服务」:读不出来如实说,也不让后续保存覆盖原文件
            self.error = "读取弹幕来源失败:\(error.localizedDescription)"
        }
    }

    private func add() async {
        var updated = settings
        updated.customSources.append(DanmakuCustomSource(name: trimmedName, baseURL: trimmedAddress))
        if await save(updated) {
            newName = ""
            newAddress = ""
        }
    }

    @discardableResult
    private func save(_ updated: DanmakuSourceSettings) async -> Bool {
        do {
            try await danmaku.saveSourceSettings(updated)
            settings = try await danmaku.sourceSettings()
            error = nil
            return true
        } catch {
            self.error = "保存弹幕来源失败:\(error.localizedDescription)"
            return false
        }
    }
}
