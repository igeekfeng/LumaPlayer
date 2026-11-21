import SwiftUI

/// 内容页顶部大标题行:标题 + 右侧页内工具(排序 / 筛选)。
/// 主窗口没有系统工具栏,`navigationTitle` 不显示在窗口上(仍要设,「窗口」菜单与调度中心用它)。
///
/// ⚠️ 只有标题、极短数据标签与工具:⛔ 没有副标题 / 讲解句子。
/// 「这一页是干什么的」靠图标、控件形状与摆放位置说明,⛔ 不靠一行灰字(见 `CLAUDE.md`「界面文案」)。
struct PageHeader<Trailing: View>: View {
    let title: String
    /// 只放数据标签(「42 项」),⛔ 不放句子。没有数据就不传。
    var badge: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingM) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.callout.monospacedDigit())
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
    init(title: String, badge: String? = nil) {
        self.init(title: title, badge: badge) { EmptyView() }
    }
}

/// 把一段说明挂到「ⓘ」小图标上:界面上只出现图标,细节点开或悬停才显示。
///
/// ⚠️ 设置项的取舍、副作用、生效时机这类话**,一律走这里或直接删掉**,⛔ 不写成 `Section` footer 的
/// 讲解段落 —— 那会把设置页铺成说明书。
///
/// 交互:**点一下弹出气泡**显示完整说明;鼠标停留也有系统工具提示(`.help`)。
/// ⛔ 不要只靠 `.help`:macOS 要停约一秒才出提示,快速扫过时像「点了没反应」。
struct InfoHint: View {
    let text: String
    @State private var showsDetail = false

    var body: some View {
        Button {
            showsDetail = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("说明")
        .accessibilityHint(text)
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Metrics.spacingM)
                .frame(maxWidth: Metrics.infoHintPopoverWidth)
        }
    }
}