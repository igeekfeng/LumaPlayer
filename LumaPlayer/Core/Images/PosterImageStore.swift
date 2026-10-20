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
///
/// 磁盘层的上限可调、占用可查、可整片清空(设置 → 缓存),入口是这里的
/// `diskUsage()` / `setDiskByteLimit(_:)` / `clearAll()` —— 设置页只跟这一个对象打交道。
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
    func image(for descriptor: ImageDescriptor) async throws -> NSImage {
        let key = descriptor.cacheKey
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

    /// `ImageSpec` 便利入口(等价于 `.emby(spec)`)。
    func image(for spec: ImageSpec) async throws -> NSImage {
        try await image(for: .emby(spec))
    }

    /// 清空内存缓存(测试用)。磁盘层不动 —— 它按来源隔离、按容量自淘汰。
    func clearCache() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// 删除某个来源在磁盘上的全部图片(删来源时)。
    func purgeDisk(ownerID: UUID) async {
        await disk?.purge(ownerID: ownerID)
    }

    // MARK: - 设置 → 缓存(占用 / 上限 / 清空)

    /// 磁盘层当前占用;`nil` = 这一层不存在(纯内存的测试替身),设置页据此不显示数字。
    func diskUsage() async -> PosterDiskCache.Usage? {
        await disk?.usage()
    }

    /// 改磁盘上限。调低时立即淘汰(`PosterDiskCache.setByteLimit`)。
    func setDiskByteLimit(_ bytes: Int) async {
        await disk?.setByteLimit(bytes)
    }

    /// 清空**两层**缓存(设置页的「清空图片缓存」)。
    ///
    /// 屏幕上正在显示的图不受影响:每个 `PosterImage` 自己持着已解出的 `NSImage`,
    /// 清缓存不会让画面空掉;下次重新出现时按需走网络。
    func clearAll() async {
        clearCache()
        await disk?.removeAll()
    }

    /// 该 key 是否已在内存中(测试断言缓存命中用)。
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
    /// 服务端返回的字节解不出 `NSImage`(不是图片,或已损坏)
    case undecodableImage
    /// 远端地址返回了非 2xx(百度 `dlink` 过期后是 403,见 `docs/BAIDU_PAN_API.md`)
    case badResponse(status: Int)
    /// 这个加载器不认识该 origin(只有测试替身会走到:它们默认只支持 Emby 端点)
    case unsupportedOrigin
}
