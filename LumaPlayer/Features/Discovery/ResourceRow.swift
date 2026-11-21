import SwiftUI

/// 一条搜索结果的卡片:标题 + 网盘标记 + 提取码 + 操作(复制 / 打开 / 转存)。
///
/// ⛔ 不做成海报网格:搜索结果没有封面(搜索源不提供),硬画成海报位会全是灰块。
/// 列表形态才能同时装下标题、多个网盘链接和提取码。
struct ResourceRow: View {
    let resource: PanResource
    /// 「来自哪个源」的展示名
    let sourceName: String
    var onCopy: (PanResourceLink) -> Void
    var onOpen: (PanResourceLink) -> Void
    var onTransfer: (PanResourceLink) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
                Text(resource.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let date = resource.publishedAt {
                    Text(Self.dateFormatter.string(from: date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let summary = resource.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(resource.links, id: \.self) { link in
                linkRow(link)
            }
            HStack(spacing: Metrics.spacingS) {
                Text("来自 \(sourceName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(Metrics.spacingM)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(.separator, lineWidth: isHovering ? 0 : 1)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Metrics.animationFast), value: isHovering)
    }

    @ViewBuilder
    private func linkRow(_ link: PanResourceLink) -> some View {
        HStack(spacing: Metrics.spacingS) {
            Text(link.cloudType.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, Metrics.spacingS)
                .padding(.vertical, Metrics.spacingXXS)
                .background(.quaternary, in: Capsule())
            if let password = link.password, !password.isEmpty {
                Text("提取码 \(password)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // 转存:能转的才给按钮;不能转的把原因挂在 help 上,⛔ 不显示一个点了会失败的重试
            if link.cloudType.isTransferable {
                Button("转存") { onTransfer(link) }
                    .controlSize(.small)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                    .help(PanShareLink.parse(link.url)?.unsupportedReason ?? "这个链接不能转存")
            }
            Button("复制") { onCopy(link) }
                .controlSize(.small)
            Button("打开") { onOpen(link) }
                .controlSize(.small)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
