import SwiftUI

/// 应用设置(⌘,)。目前只有「网络」一组。
struct AppSettingsView: View {
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
        .frame(width: Metrics.onboardingFormWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}
