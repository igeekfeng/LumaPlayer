import SwiftUI

/// 设置 › 弹幕:弹弹play 的应用凭据 + 弹幕外观。
///
/// ## 为什么要用户自己填 AppId / AppSecret
///
/// 弹弹play 开放平台按应用发凭据,官方明确要求不要把 AppSecret 硬编码进客户端;
/// 本项目没有自己的服务器可以代签名,所以由用户去开发者中心(dev.dandanplay.com)
/// 申请自己的应用并填在这里(`docs/DANDANPLAY_API.md` §1)。
/// 存凭据文件(`CredentialStore`,0600、不进备份),⛔ 不进 UserDefaults、不进仓库。
/// AppSecret 只用于本地算签名,不会作为请求头发出去。
struct DanmakuSettingsView: View {
    let credentials: CredentialStore
    @Bindable var store: DanmakuSettingsStore

    var body: some View {
        Form {
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

/// AppId / AppSecret 的输入。做法与「元数据刮削」的 TMDB token 一致:
/// 保存才落盘、两项都留空 = 清除、读不出来如实报错。
///
/// ⛔ 不做「测试连接」按钮:弹弹play 对接口有滥用检测,验证就留给第一次播放时的真实请求。
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
                    .disabled(saved.appID.isEmpty && saved.appSecret.isEmpty && appID.isEmpty && appSecret.isEmpty)
                Button("保存") { Task { await save() } }
                    .disabled(edited == saved || (edited.appID.isEmpty != edited.appSecret.isEmpty))
            }
        } header: {
            Text("弹弹play 凭据")
        } footer: {
            Text("在 dev.dandanplay.com 注册开发者、创建应用并通过审核后获得。只写在本机凭据文件里;AppSecret 只用于在本机计算请求签名,不会被发送出去。")
        }
        .task { await load() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            Text(saved.isComplete ? "已配置" : "未配置,不加载弹幕").foregroundStyle(.secondary)
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
            if value.appID.isEmpty && value.appSecret.isEmpty {
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
