import SwiftUI

/// 夸克网盘登录:扫码换 token(`docs/QUARK_API.md` §4)。
///
/// ⚠️ 与 115 的一处关键差别:夸克给的是**二维码图片本身**(base64 PNG),不是要编进二维码的文本。
/// 所以这里直接把它解成 `NSImage` 显示,⛔ 不套 `CIQRCodeGenerator`。
///
/// 合规提示(§10)必须留在界面上:夸克没有面向个人的开放 API,这套是逆向 TV 接口;
/// 换 token 要经过**第三方服务**(`api.extscreen.com`),登录态会经过它,风险自负。
struct QuarkAuthorizationView: View {
    let viewModel: FileSourceViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    OnboardingFormHeader(
                        systemImage: "qrcode",
                        title: "登录夸克网盘",
                        subtitle: "用手机上的夸克 App 扫码。登录后 LumaPlayer 只读取网盘内容,不会修改文件。"
                    )

                    qrPane

                    OnboardingNotice(
                        text: "夸克没有面向个人的开放 API,这里是非官方的 TV 端接口。"
                            + "扫码后的登录凭据会经过第三方服务(api.extscreen.com)换取,"
                            + "该服务不是夸克官方域名,请自行判断是否继续。"
                            + "这个来源**只读**:可以浏览与播放,不能删除 / 改名 / 移动网盘里的文件。",
                        style: .warning
                    )
                }
                .frame(maxWidth: Metrics.onboardingFormWidth)
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.vertical, Metrics.spacingL)
            }

            HStack(spacing: Metrics.spacingM) {
                if viewModel.isWaitingForAuthorization {
                    Button("取消") { viewModel.cancelQuarkAuthorization() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("已完成扫码,重试") { Task { await viewModel.reload() } }
                    .disabled(viewModel.isWaitingForAuthorization)
            }
            .padding(.bottom, Metrics.spacingXL)
        }
        // ⚠️ 只在没在等的时候自动起一次:重复起会多要一张二维码,而且旧那张会被作废。
        .task {
            guard !viewModel.isWaitingForAuthorization, viewModel.quarkQRCode == nil else { return }
            await viewModel.startQuarkAuthorization()
        }
    }

    @ViewBuilder
    private var qrPane: some View {
        Group {
            if let session = viewModel.quarkQRCode {
                VStack(spacing: Metrics.spacingS) {
                    if let image = Self.image(base64: session.imageBase64) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                    } else {
                        // 解不出来时如实说明,⛔ 不假装拿到了二维码
                        RoundedRectangle(cornerRadius: Radius.card)
                            .fill(.quaternary)
                            .frame(width: 180, height: 180)
                            .overlay(Text("二维码图片解析失败").font(.caption))
                    }
                    if viewModel.isWaitingForAuthorization {
                        ProgressView()
                            .controlSize(.small)
                        Text("等待你在夸克 App 上确认(\(Int(QuarkQRCodeSession.validitySeconds / 60)) 分钟内有效)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if viewModel.isWaitingForAuthorization {
                ProgressView("正在获取二维码…")
            } else {
                VStack(spacing: Metrics.spacingS) {
                    Button("获取登录二维码") { Task { await viewModel.startQuarkAuthorization() } }
                        .buttonStyle(.borderedProminent)
                    if viewModel.loadFailure != nil {
                        Button("换一张二维码") { Task { await viewModel.restartQuarkAuthorization() } }
                    }
                }
            }
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
    }

    /// 夸克给的是 base64 编码的 PNG 字节,不是二维码内容。
    static func image(base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return NSImage(data: data)
    }
}
