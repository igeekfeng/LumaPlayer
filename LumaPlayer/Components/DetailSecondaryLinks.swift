import SwiftUI
import AppKit

/// 详情页底部的次要出口:TMDB 标识(点开这一部在 TMDB 上的页面)与图片墙。
///
/// 这两件事都是偶尔用一次的,⛔ 不占操作条 —— 那里只留播放 / 已看 / 收藏这类高频动作,
/// 也不做成玻璃按钮:标识保持官方配色本身,图片墙跟「更多 / 收起」一样是文字链接。
/// 传 nil 的那一项整块不画。
struct DetailSecondaryLinks: View {
    /// TMDB 页面地址;nil = 不显示
    var tmdbURL: URL?
    /// 打开图片墙;nil = 不显示
    var onShowImages: (() -> Void)?

    var body: some View {
        if tmdbURL != nil || onShowImages != nil {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingL) {
                if let tmdbURL {
                    Button {
                        NSWorkspace.shared.open(tmdbURL)
                    } label: {
                        TMDBLogoMark(height: Metrics.detailSecondaryMarkHeight)
                    }
                    .buttonStyle(.plain)
                    .help("在 TMDB 上打开")
                    .accessibilityLabel("在 TMDB 上打开")
                }
                if let onShowImages {
                    Button("浏览图片", action: onShowImages)
                        .buttonStyle(.link)
                        .help("TMDB 的背景图 / 海报 / Logo")
                }
            }
        }
    }
}
