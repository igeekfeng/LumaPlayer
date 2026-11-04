import SwiftUI

/// 115 网盘登录:扫码换 Cookie 四件套。
///
/// ⚠️ 只有一屏,与百度的两屏不同 —— 115 没有开放平台应用要填,凭据就是网页登录后的 Cookie。
/// Cookie 全 App 一份,所以这里的扫码对所有 115 来源生效。
///
/// 合规提示(§8)必须留在界面上:115 用户协议禁止「非授权客户端或接口」批量调用平台资源,
/// 停服后的 Cookie 链路属于未授权通道,存在账号被限流 / 封禁的风险。
struct Pan115AuthorizationView: View {
    let viewModel: FileSourceViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacingL) {
                    OnboardingFormHeader(
                        systemImage: "qrcode",
                        title: "登录 115 网盘",
                        subtitle: "用手机上的 115 App 扫码。登录后 LumaPlayer 只读取网盘内容,不会修改文件。"
                    )

                    qrPane

                    OnboardingNotice(
                        text: "115 的开放平台 API 已暂停服务,这里是非官方的 Cookie 直连接口。"
                            + "扫码会以「\(Pan115AuthorizationApp.default.displayName)」渠道拿 Cookie,"
                            + "与网页端分属不同组、通常不再互顶(二维码仍用手机 115 App 扫)。"
                            + "115 用户协议禁止使用非授权客户端或接口调用平台资源,"
                            + "存在被限流甚至封禁账号的风险 —— 请自行判断是否继续。",
                        style: .warning
                    )
                }
                .frame(maxWidth: Metrics.onboardingFormWidth)
                .padding(.horizontal, Metrics.spacingXL)
                .padding(.vertical, Metrics.spacingL)
            }

            HStack(spacing: Metrics.spacingM) {
                if viewModel.isWaitingForAuthorization {
                    Button("取消") { viewModel.cancelPan115Authorization() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("已完成扫码,重试") { Task { await viewModel.reload() } }
                    .disabled(viewModel.isWaitingForAuthorization)
            }
            .padding(.bottom, Metrics.spacingXL)
        }
        // ⚠️ 只在没在等的时候自动起一次:重复起会多要一张二维码,而且旧那张会被作废。
        .task {
            guard !viewModel.isWaitingForAuthorization, viewModel.pan115QRCode == nil else { return }
            await viewModel.startPan115Authorization()
        }
    }

    @ViewBuilder
    private var qrPane: some View {
        Group {
            if let session = viewModel.pan115QRCode {
                VStack(spacing: Metrics.spacingS) {
                    if let image = BaiduPanAuthorizationView.qrImage(content: session.content, size: 180) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .frame(width: 180, height: 180)
                    } else {
                        // 渲染不出来时至少把内容摆出来,让人能自己搜 —— 115 的二维码就是一段 URL
                        RoundedRectangle(cornerRadius: Radius.card)
                            .fill(.quaternary)
                            .frame(width: 180, height: 180)
                            .overlay(Text("二维码渲染失败").font(.caption))
                    }
                    if viewModel.isWaitingForAuthorization {
                        ProgressView()
                            .controlSize(.small)
                        Text("等待你在手机上确认(\(Int(Pan115QRCodeSession.validitySeconds / 60)) 分钟内有效)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if viewModel.isWaitingForAuthorization {
                ProgressView("正在获取二维码…")
            } else {
                VStack(spacing: Metrics.spacingS) {
                    Button("获取登录二维码") { Task { await viewModel.startPan115Authorization() } }
                        .buttonStyle(.borderedProminent)
                    if viewModel.loadFailure != nil {
                        Button("换一张二维码") { Task { await viewModel.restartPan115Authorization() } }
                    }
                }
            }
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
    }
}
