import SwiftUI

/// 海报 / 背景图。⛔ 项目里唯一允许发起图片请求的地方:Emby 图片要带 `X-Emby-Token`,
/// 裸 `AsyncImage` 发不出(API_CONTRACT.md 3.3)。
///
/// - `spec == nil`:没有图片 tag,不发请求(会 404)。
/// - `fallbackSpec`:首选缺失或取不到时的退路(如横版卡片退回竖版海报)。
/// - `showsPlaceholder = false`:取不到时透明,给叠在别的图层上的图用。
/// - `onLoadResult`:首选与退路都试完后回报一次是否拿到图。
struct PosterImage: View {
    let descriptor: ImageDescriptor?
    let store: PosterImageStore
    private let fallback: ImageDescriptor?

    /// 占位图右下角的系统图标名(nil = 无图,不是加载失败)
    private var placeholderSystemImage: String
    private let showsPlaceholder: Bool
    private let onLoadResult: (@MainActor (Bool) -> Void)?

    @State private var image: NSImage?

    /// 来源无关入口(非 Emby 图走这条)
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

    /// Emby 便利入口
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
            // 首选失败 → 试退路,都失败停在占位图。图片失败不是页面级错误:不弹窗、不重试
            await loadFallback()
        }
    }

    private func loadFallback() async {
        guard let fallback else { return }
        do {
            image = try await store.image(for: fallback)
        } catch {
            image = nil
        }
    }
}
