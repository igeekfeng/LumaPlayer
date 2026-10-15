import SwiftUI

/// 内容页顶部的大标题行:标题 + 副标题(如「共 42 项」)+ 右侧页内工具(排序 / 筛选)。
///
/// 主窗口没有系统工具栏(见 `BrowseChromeBar.swift`),`navigationTitle` 不再显示在窗口上
/// (仍保留,「窗口」菜单与调度中心里用它),页面名称与页内工具画在这里。
/// 首页与详情页不用它:它们的 hero 本身就是标题。
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.bottom, Metrics.spacingM)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
