import AppKit
import Foundation

/// 海报图片的内存缓存(@MainActor:缓存的是 `NSImage`,不跨隔离传递)。
///
/// ⛔ 图片请求只走 `Components/PosterImage.swift`(该文件的注释写了原因:
/// 图片端点要带 `X-Emby-Token`,系统自带的异步图片视图发不出自定义头)。
///
/// 加载顺序:**内存 → 磁盘 → 网络**(磁盘层是 `PosterDiskCache`;
/// 没有它时重启即重拉、超限全清,切回服务器图片全部重新加载)。
/// 网络成功后同时写内存与磁盘。
///
/// 内存淘汰是 **LRU**(超限只淘汰最久未用的那一条):内存里留着哪张图
/// 与「最近在看哪个库」强相关,全表清空会让另一台服务器的海报无辜陪葬。
@MainActor
final class PosterImageStore {
    /// 内存条目上限。不是设计 token,与布局无关。
    static let cacheLimit = 300

    private let loader: any ImageDataLoading
    private let disk: PosterDiskCache?
    private var cache: [String: NSImage] = [:]
    /// 最近访问顺序(尾部最新),LRU 淘汰队头的。
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<NSImage, any Error>] = [:]

    init(loader: any ImageDataLoading, disk: PosterDiskCache? = nil) {
        self.loader = loader
        self.disk = disk
    }

    /// 取图片:内存 → 磁盘 → 网络三层,同一 key 的并发请求合并为一次网络请求。
    func image(for spec: ImageSpec) async throws -> NSImage {
        let key = spec.cacheKey
        if let cached = cache[key] {
            touchAccessOrder(key)
            return cached
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        // 磁盘读也放进 inFlight 登记的 Task 里:若在登记前 await 磁盘,
        // 挂起期间同 key 的其他调用会穿过上面的 inFlight 检查各自发网络请求
        let loader = self.loader
        let disk = self.disk
        let task = Task { () -> NSImage in
            // 磁盘层:命中后由下面回填内存,下次连磁盘都不用读
            if let disk, let data = await disk.data(for: spec),
               let image = NSImage(data: data) {
                return image
            }
            let data = try await loader.data(for: spec)
            guard let image = NSImage(data: data) else {
                throw PosterImageError.undecodableImage
            }
            await disk?.store(data, for: spec)
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

    /// 清空内存缓存(测试用)。磁盘层不动 —— 它按服务器隔离、按容量自淘汰。
    func clearCache() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// 删除这台服务器在磁盘上的全部图片(删服务器时)。
    func purgeDisk(serverID: UUID) async {
        await disk?.purge(serverID: serverID)
    }

    /// 该 key 是否已在内存中(测试断言缓存命中用)。
    func isCached(_ spec: ImageSpec) -> Bool {
        cache[spec.cacheKey] != nil
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
    /// 服务端返回的字节解不出 `NSImage`(不是图片,或已损坏)
    case undecodableImage
}
