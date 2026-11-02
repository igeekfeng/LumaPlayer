import Foundation

/// `fsID → pick_code` 的旁路缓存。
///
/// 为什么不塞进 `BaiduPanFile`:`BaiduPanFile` 是「文件树来源」的通用形状(`LocalFolderListing`
/// 也在用它),`pick_code` 只有 115 有,塞进去会让另外两家凭空多一个永远为 nil 的字段。
///
/// 只在内存里,不落盘:进程重启后第一次进目录会重新列一次,这是可接受的代价,
/// 换来的是**不会拿着过期的 pick_code 去取直链**(115 换目录/改名后 pick_code 会变)。
actor Pan115PickCodeCache {
    private var storage: [UInt64: String] = [:]

    func store(_ pickCode: String, for fsID: UInt64) {
        storage[fsID] = pickCode
    }

    func pickCode(for fsID: UInt64) -> String? {
        storage[fsID]
    }

    /// 目录被重新列出时整批刷新;旧条目保留(用户在上一级目录点播放不该突然失效)。
    func store(_ entries: [UInt64: String]) {
        storage.merge(entries) { _, new in new }
    }

    func purge() {
        storage.removeAll()
    }

    /// 单条失效(取直链回 403 后,调用方清掉它下次重新列目录)。
    func forget(fsID: UInt64) {
        storage.removeValue(forKey: fsID)
    }
}
