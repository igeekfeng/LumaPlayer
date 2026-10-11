import SwiftUI
import AppKit
import CoreImage

/// 百度网盘授权:配置密钥 → 扫码 → 完成。
///
/// 分两屏是刻意的:**缺密钥**与**缺授权**是两件不同的事
/// (前者要去开放平台建应用,后者扫码就行)。合成一个「未授权」会让人找不到北。
struct BaiduPanAuthorizationView: View {
    let viewModel: BaiduPanSourceViewModel

    @State private var appKey = ""
    @State private var secretKey = ""
    @State private var folderName = ""
    @State private var isSaving = false

    var body: some View {
        Group {
            if case .unconfigured = viewModel.authorization {
                configurationForm
            } else {
                deviceCodePane
            }
        }
    }

    // MARK: - 配置密钥

    private var configurationForm: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    OnboardingFormHeader(
                        systemImage: "cloud.fill",
                        title: "接入百度网盘",
                        subtitle: "在开放平台建一个应用,把它的 API Key、Secret Key 与应用目录名填进来。"
                    )

                    VStack(alignment: .leading, spacing: Metrics.spacingM) {
                        Text("应用目录名")
                            .font(.headline)
                        TextField("例如 LumaPlayer", text: $folderName)
                            .textFieldStyle(.roundedBorder)
                        Text("第三方应用只能访问网盘里的 **/我的应用数据/{这个目录}**。"
                             + "它必须与开放平台建应用时填的「应用名称」**完全一致,包括大小写**。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("⚠️ 这一层**不是普通文件夹**:`apps` 是百度的保留关键字,"
                             + "自己在网盘里建不出来。目录由百度在应用首次读取时自动建出;"
                             + "若还没出现,就到网盘的「我的应用数据」里新建一个同名文件夹。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: Metrics.spacingM) {
                        Text("API Key 与 Secret Key")
                            .font(.headline)
                        TextField("API Key(AppKey)", text: $appKey)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Secret Key", text: $secretKey)
                            .textFieldStyle(.roundedBorder)
                        Text("控制台 → 我的应用 → 应用详情里能看到。两串密钥只存在本机凭据文件里,"
                             + "不会上传给任何第三方。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    OnboardingNotice(
                        text: "百度网盘的第三方应用权限很窄:只有这个目录下的文件能播。"
                            + "要全盘访问得走 IoT 设备入驻(需商务对接)。",
                        style: .warning
                    )
                }
                .frame(maxWidth: Metrics.onboardingFormWidth)
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.vertical, Metrics.spacingL)
            }
            OnboardingActionBar(
                primaryTitle: isEditing ? "保存" : "保存并授权",
                busyTitle: "正在保存…",
                isBusy: isSaving,
                canSubmit: canSave,
                // 从「读不到应用目录」那条路进来改名字时,给个退路 ——
                // 不改了就回到原来那一屏,⛔ 别让人只能硬着头皮提交。
                onCancel: isEditing ? { Task { await viewModel.cancelConfigurationEdit() } } : nil,
                onSubmit: save
            )
        }
        .task(seedFromDraft)
    }

    /// 是不是「已授权之后回头改配置」。首次配置时 `configurationDraft` 为 nil。
    private var isEditing: Bool { viewModel.configurationDraft != nil }

    /// 用现值预填表单。⛔ 只填空着的:用户已经在改的字段不该被覆盖。
    private func seedFromDraft() {
        guard let draft = viewModel.configurationDraft else { return }
        if appKey.isEmpty { appKey = draft.appKey }
        if secretKey.isEmpty { secretKey = draft.secretKey }
        if folderName.isEmpty { folderName = draft.folderName }
    }

    private var canSave: Bool {
        !appKey.trimmed.isEmpty && !secretKey.trimmed.isEmpty && !folderName.trimmed.isEmpty
    }

    private func save() {
        isSaving = true
        Task {
            await viewModel.saveConfiguration(
                appKey: appKey, secretKey: secretKey, folderName: folderName)
            isSaving = false
        }
    }

    // MARK: - 扫码

    private var deviceCodePane: some View {
        VStack(spacing: Metrics.spacingL) {
            OnboardingFormHeader(
                systemImage: "qrcode",
                title: "用手机扫码授权",
                subtitle: "用百度网盘 App 扫一下,或者打开下面的地址输入用户码。"
            )

            Group {
                if let code = viewModel.deviceCode {
                    qrCodePane(code)
                } else if viewModel.isWaitingForAuthorization {
                    ProgressView("正在获取二维码…")
                } else {
                    Button("重新获取二维码") { Task { await viewModel.startAuthorization() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(height: 260)

            if let notice = viewModel.notice {
                OnboardingNotice(text: notice, style: .warning)
            }

            Spacer()

            HStack(spacing: Metrics.spacingM) {
                if viewModel.isWaitingForAuthorization {
                    Button("取消") { viewModel.cancelAuthorization() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("完成授权后重试") { Task { await viewModel.reload() } }
                    .disabled(viewModel.isWaitingForAuthorization)
            }
            .padding(.bottom, Metrics.spacingXL)
        }
        // ⚠️ 只在**没在等**的时候自动起一次:两条路径都能进到这里
        // (首次进入、以及用户在手机上取消之后),重复起会多要一次设备码。
        .task {
            guard !viewModel.isWaitingForAuthorization, viewModel.deviceCode == nil else { return }
            await viewModel.startAuthorization()
        }
    }

    @ViewBuilder
    private func qrCodePane(_ code: BaiduPanDeviceCode) -> some View {
        VStack(spacing: Metrics.spacingS) {
            if let image = Self.qrImage(content: code.qrCodeContent, size: 180) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(width: 180, height: 180)
            } else {
                // ⛔ 渲染不出来也要把用户码摆出来 —— 那是第二种授权方式
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(.quaternary)
                    .frame(width: 180, height: 180)
                    .overlay(Text("二维码渲染失败").font(.caption))
            }

            Text(code.userCode)
                .font(.title3.monospacedDigit())
                .textSelection(.enabled)

            if let url = code.verificationURL {
                Text("或打开 \(url.absoluteString) 输入上面的用户码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if viewModel.isWaitingForAuthorization {
                ProgressView()
                    .controlSize(.small)
                Text("等待你在手机上确认(二维码 \(Int(code.expiresIn / 60)) 分钟内有效)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 二维码

    /// 本地渲染二维码。内容是官方给的规则串(`qrCodeContent`),
    /// 不额外发一次请求去取 `qrcode_url` 那张图。
    static func qrImage(content: String, size: CGFloat) -> NSImage? {
        guard let data = content.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // 纠错等级 H:二维码里只有一个短 URL,取最高档不影响可读性
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / max(output.extent.width, 1)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
