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
///
/// `fallbackSpec` 是**首选图加载失败时的退路**(默认 nil = 没有退路)。
/// 横版卡片用它兜住两种真实情况:响应里根本没有横版 tag,或者有 tag 但服务端
/// 那张图取不到(`LandscapeCard` 传自己的竖版海报)。
///
/// `showsPlaceholder = false`:取不到图时什么都不画(透明),给叠在别的图层上的图用
/// (首页 hero 的背景图叠在模糊海报上、Logo 取不到时换成文字标题)。
/// `onLoadResult` 在首选与退路都试完后回报一次「有没有拿到图」。
struct PosterImage: View {
    let descriptor: ImageDescriptor?
    let store: PosterImageStore
    /// 首选图失败 / 缺失时改请求这张;`nil` 就停在占位图
    private let fallback: ImageDescriptor?

    /// 占位图右下角的系统图标名(nil = 无图,不是加载失败)
    private var placeholderSystemImage: String
    private let showsPlaceholder: Bool
    private let onLoadResult: (@MainActor (Bool) -> Void)?

    @State private var image: NSImage?

    /// 来源无关入口(百度封面等非 Emby 图走这条)
    init(
        descriptor: ImageDescriptor?,
        fallback: ImageDescriptor? = nil,
        store: PosterImageStore,
        placeholderSystemImage: String = "photo",
        showsPlaceholder: Bool = true,
        onLoadResult: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.fallback = fallback
        self.store = store
        self.placeholderSystemImage = placeholderSystemImage
        self.showsPlaceholder = showsPlaceholder
        self.onLoadResult = onLoadResult
    }

    /// Emby 便利入口(等价于把两个 `ImageSpec` 包成 `.emby` descriptor)
    init(
        spec: ImageSpec?,
        fallbackSpec: ImageSpec? = nil,
        store: PosterImageStore,
        placeholderSystemImage: String = "photo",
        showsPlaceholder: Bool = true,
        onLoadResult: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.init(
            descriptor: spec.map { .emby($0) },
            fallback: fallbackSpec.map { .emby($0) },
            store: store,
            placeholderSystemImage: placeholderSystemImage,
            showsPlaceholder: showsPlaceholder,
            onLoadResult: onLoadResult
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if showsPlaceholder {
                placeholder
            } else {
                Color.clear
            }
        }
        // descriptor 变化(换条目 / 换来源)时重新加载:cacheKey 含来源 id 与版本
        .task(id: descriptor?.cacheKey ?? fallback?.cacheKey) {
            await load()
            // 视图消失导致的取消不算「取不到图」,不回报
            guard !Task.isCancelled else { return }
            onLoadResult?(image != nil)
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
        guard let descriptor else {
            // 首选就没有图(不请求):有退路就试退路,没有就停在占位图
            await loadFallback()
            return
        }
        do {
            image = try await store.image(for: descriptor)
        } catch {
            // 首选图失败(404 / 403 / 断网)→ 试退路;退路也失败就停在占位图。
            // 图片加载失败不是页面级错误:留占位图即可,不弹窗、不重试风暴
            // (报告失败但不打断浏览,与 DesignTokens.swift「界面规则」一致)。
            await loadFallback()
        }
    }

    private func loadFallback() async {
        guard let fallback else { return }
        do {
            image = try await store.image(for: fallback)
        } catch {
            // 同首选:失败就停在占位图,不升级成页面级错误
            image = nil
        }
    }
}
