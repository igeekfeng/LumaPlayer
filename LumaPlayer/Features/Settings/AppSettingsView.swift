import SwiftUI

/// 设置窗口(⌘,)。两个标签页:
///
/// - **通用**:网络(自定义 User-Agent);
/// - **服务器**:服务器管理(增 / 改 / 删 / 切换 / 登录,`ServerListView`)。
///
/// 服务器管理原先是主窗口左栏里的一个整页(`AppRoute.serverList`)。左栏去掉后
/// 归到这里 —— 它是低频的配置动作,不属于日常浏览路径(UI_DESIGN.md 3.1)。
struct AppSettingsView: View {
    let container: AppContainer

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ServerListView(container: container)
                .tabItem { Label("服务器", systemImage: "server.rack") }
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
