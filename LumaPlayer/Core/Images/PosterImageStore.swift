import AppKit
import Foundation

/// 海报图片缓存:内存(LRU)→ 磁盘(`PosterDiskCache`)→ 网络,网络成功后两层都写。
/// @MainActor 因为缓存的是 `NSImage`。⛔ 图片请求只经 `Components/PosterImage.swift` 触发。
///
/// 设置页的占用 / 上限 / 清空只经这里(`diskUsage()` / `setDiskByteLimit(_:)` / `clearAll()`)。
@MainActor
final class PosterImageStore {
    /// 内存条目上限
    static let cacheLimit = 300

    private let loader: any ImageDataLoading
    private let disk: PosterDiskCache?
    private var cache: [String: NSImage] = [:]
    /// 尾部最新,淘汰队头
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<NSImage, any Error>] = [:]

    init(loader: any ImageDataLoading, disk: PosterDiskCache? = nil) {
        self.loader = loader
        self.disk = disk
    }

    /// 同一 key 的并发请求合并为一次。
    func image(for descriptor: ImageDescriptor) async throws -> NSImage {
        let key = descriptor.cacheKey
        if let cached = cache[key] {
            touchAccessOrder(key)
            return cached
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        // 磁盘读也要放进登记的 Task:登记前 await 的话,挂起期间同 key 调用会穿过 inFlight 检查各发一次请求
        let loader = self.loader
        let disk = self.disk
        let task = Task { () -> NSImage in
            if let disk, let data = await disk.data(for: descriptor),
               let image = NSImage(data: data) {
                return image
            }
            let data = try await loader.data(for: descriptor)
            guard let image = NSImage(data: data) else {
                throw PosterImageError.undecodableImage
            }
            await disk?.store(data, for: descriptor)
            return image
        }
        inFlight[key] = task
        do {
            let image = try await task.value
            inFlight[key] = nil
            storeInMemory(image, key: key)
            return image
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func image(for spec: ImageSpec) async throws -> NSImage {
        try await image(for: .emby(spec))
    }

    /// 只清内存(测试用),磁盘层不动。
    func clearCache() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    func purgeDisk(ownerID: UUID) async {
        await disk?.purge(ownerID: ownerID)
    }

    // MARK: - 设置 → 缓存(占用 / 上限 / 清空)

    /// nil = 没有磁盘层(测试替身),设置页不显示数字。
    func diskUsage() async -> PosterDiskCache.Usage? {
        await disk?.usage()
    }

    /// 调低时立即淘汰。
    func setDiskByteLimit(_ bytes: Int) async {
        await disk?.setByteLimit(bytes)
    }

    /// 清两层。正在显示的图不受影响(每个 `PosterImage` 自己持着 `NSImage`)。
    func clearAll() async {
        clearCache()
        await disk?.removeAll()
    }

    /// 是否在内存中(测试用)。
    func isCached(_ descriptor: ImageDescriptor) -> Bool {
        cache[descriptor.cacheKey] != nil
    }

    func isCached(_ spec: ImageSpec) -> Bool {
        isCached(.emby(spec))
    }

    // MARK: - 内部

    private func storeInMemory(_ image: NSImage, key: String) {
        if cache[key] == nil, accessOrder.count >= Self.cacheLimit, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
        cache[key] = image
        touchAccessOrder(key)
    }

    private func touchAccessOrder(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

enum PosterImageError: Error, Equatable {
    case undecodableImage
    /// 非 2xx(`dlink` 过期是 403)
    case badResponse(status: Int)
    /// 只有测试替身会走到(默认只支持 Emby 端点)
    case unsupportedOrigin
}
