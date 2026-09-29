import SwiftUI

/// 海报 / 背景图。
///
/// ⛔ 这是项目里**唯一**允许发起图片请求的地方(
/// `grep -rn 'AsyncImage' LumaPlayer/` 除本文件外不得有输出)。
/// 原因:Emby 图片端点要带 `X-Emby-Token`,裸 `AsyncImage` 发不出认证头
/// (API_CONTRACT.md 3.3)。
///
/// `spec == nil` 表示「这个 Item 没有对应的图片 tag」,此时**不发请求** ——
/// 没有 tag 去请求图片只会拿到 404(API_CONTRACT.md 3.3)。
struct PosterImage: View {
    let spec: ImageSpec?
    let store: PosterImageStore

    /// 占位图右下角的系统图标名(nil = 无图,不是加载失败)
    private var placeholderSystemImage: String

    @State private var image: NSImage?

    init(spec: ImageSpec?, store: PosterImageStore, placeholderSystemImage: String = "photo") {
        self.spec = spec
        self.store = store
        self.placeholderSystemImage = placeholderSystemImage
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        // spec 变化(换 Item / 换服务器)时重新加载:cacheKey 含 serverID、itemID 与 tag
        .task(id: spec?.cacheKey) {
            await load()
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.card)
                .fill(.quaternary)
            Image(systemName: placeholderSystemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func load() async {
        image = nil
        guard let spec else { return }
        do {
            image = try await store.image(for: spec)
        } catch {
            // 图片加载失败不是页面级错误:留占位图即可,不弹窗、不重试风暴
            // (报告失败但不打断浏览,与 UI_DESIGN.md 7.2 一致)。
            image = nil
        }
    }
}
