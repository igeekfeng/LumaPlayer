import Foundation
import os

/// 本地「隐藏条目」库:用户不想再看到的条目(**不动网盘上的文件**)。
///
/// ## 为什么不是服务端能力
///
/// Emby 那边的「移出继续观看」能写回服务端(`HideFromResume`),而百度网盘
/// 没有这类标记接口(`docs/BAIDU_PAN_API.md`)。所以「让它从列表里消失但文件
/// 还在」这件事只能记在本地 —— 与 `WatchProgressStore` 同一个理由、同一套做法。
///
/// ## 与「删除」的分工
///
/// - **只隐藏**:写一条到这里,条目从列表 / 换集队列 / 续播区消失;
/// - **连网盘一起删**:⛔ **不写这里** —— 文件已经不在网盘了,记一条只会让
///   「已隐藏」列表越积越多,而且恢复不出任何东西。
///
/// 隐藏是**可恢复**的(设置页「已隐藏」),所以它比真删安全:这也是删除确认
/// 面板里那个勾选框默认不勾的原因。
///
/// ⚠️ 隐藏**目录**时,它下面所有分集的「继续观看」卡片也要一起消失
/// (`BaiduPanSourceViewModel.loadResumeCards` 用 `hiddenPaths` 过滤);
/// 只按 `fs_id` 过滤挡不住它们 —— 卡片记的是集文件的 id,不是目录的。
///
/// ⚠️ 落点与凭据文件同级(`Library/Application Support/LumaPlayer/`)。
actor HiddenItemsStore {

    /// 一条隐藏记录。
    ///
    /// ⚠️ 只留**恢复、展示与路径过滤**要的东西:身份(`ref`)决定过滤谁,`title` 给设置页
    /// 显示,`path` 让「隐藏了一个目录」能连带遮住目录里各集的续播卡片。
    /// ⛔ 不存别的(大小 / 修改时间那一类):删接口要的定位信息只有 `path` 一项,
    /// 多存一份就会多一条容易不同步的路。
    struct Item: Codable, Sendable, Equatable, Identifiable {
        let ref: SourceItemRef
        /// 隐藏那一刻的条目标题(设置页显示用;真名叫什么都可能变)
        let title: String
        let hiddenAt: Date
        /// 隐藏那一刻它在网盘上的路径(文件或目录)。
        ///
        /// ⚠️ **后加的**,老记录没有(解码成 nil),行为退回「只按 `ref` 过滤」。
        /// 它只服务一件事:隐藏一个**目录**时,把目录里各集的续播卡片一并滤掉 ——
        /// 那些记录记的是集文件的 `fs_id`,按 `ref` 过滤挡不住。
        var path: String? = nil
        /// 隐藏的是不是目录。与之配套,老记录一律按「单条文件」处理(只认路径完全相等)。
        var isDirectory: Bool = false

        /// 与存储键同形,也给设置页的 `List` 当 id
        var id: String { "\(ref.sourceID.uuidString)|\(ref.itemID)" }

        init(
            ref: SourceItemRef,
            title: String,
            hiddenAt: Date,
            path: String? = nil,
            isDirectory: Bool = false
        ) {
            self.ref = ref
            self.title = title
            self.hiddenAt = hiddenAt
            self.path = path
            self.isDirectory = isDirectory
        }

        /// 解码时把后加的两格当**可选**读。
        ///
        /// ⚠️ 不能靠合成的解码器 + 属性默认值:`Bool` 是非可选字段,合成实现会走
        /// `decode` 而不是 `decodeIfPresent`,老文件缺这个键就整份解码失败 ——
        /// 那等于「升级一次,隐藏列表全丢」(`CLAUDE.md` 硬规则 4 的迁移纪律)。
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ref = try container.decode(SourceItemRef.self, forKey: .ref)
            title = try container.decode(String.self, forKey: .title)
            hiddenAt = try container.decode(Date.self, forKey: .hiddenAt)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        }
    }

    /// 一条「隐藏了哪个路径」的规则(续播卡片的过滤用)。
    struct HiddenPath: Sendable, Equatable {
        let path: String
        let isDirectory: Bool
    }

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "hidden-items")

    private let fileURL: URL
    private var loaded: [String: Item]?
    /// 读盘失败的原因(诊断用)。**不静默吞**:读到损坏的文件时把原因留下来,
    /// 由调用方决定要不要提示;⛔ 不假装「没有记录」然后继续。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 生产路径:与凭据文件、续播库同在应用支持目录下。
    ///
    /// ⚠️ 测试宿主用**另一个文件名**:单元测试跑在宿主 App 进程里、共享真实
    /// 沙盒容器,写同一个文件会把真实记录冲掉。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost ? "hidden-items-testhost.json" : "hidden-items.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 某个来源下被隐藏的身份集合。列表过滤用 —— 视图层拿它做同步过滤,
    /// ⛔ 不能在计算属性里 await。
    func hiddenRefs(sourceID: UUID) -> Set<SourceItemRef> {
        Set(entries().values.filter { $0.ref.sourceID == sourceID }.map(\.ref))
    }

    /// 某个来源下**隐藏了哪些路径**(续播卡片的过滤用)。
    ///
    /// ⚠️ 与 `hiddenRefs` 分开:那个按条目的 `fs_id` 过滤列表,挡不住续播卡片 ——
    /// 卡片记的是**集文件**的 id,而用户隐藏的可能是它所在的**目录**。
    /// 没有 `path` 的老记录不出现在这里(它们本来也没有目录语义可判)。
    func hiddenPaths(sourceID: UUID) -> [HiddenPath] {
        entries().values
            .filter { $0.ref.sourceID == sourceID }
            .compactMap { item in
                guard let path = item.path, !path.isEmpty else { return nil }
                return HiddenPath(path: path, isDirectory: item.isDirectory)
            }
    }

    /// 全部隐藏记录(设置页用),最近隐藏的在前。
    func all() -> [Item] {
        entries().values.sorted { $0.hiddenAt > $1.hiddenAt }
    }

    func isHidden(_ ref: SourceItemRef) -> Bool {
        entries()[Self.key(for: ref)] != nil
    }

    // MARK: - 写

    func hide(_ item: Item) throws {
        var current = entries()
        current[Self.key(for: item.ref)] = item
        try persist(current)
    }

    /// 恢复:从隐藏列表里去掉。条目本身还在网盘,所以下一次列目录它就会回来。
    func restore(_ ref: SourceItemRef) throws {
        var current = entries()
        guard current.removeValue(forKey: Self.key(for: ref)) != nil else { return }
        try persist(current)
    }

    // MARK: - 内部

    private static func key(for ref: SourceItemRef) -> String {
        "\(ref.sourceID.uuidString)|\(ref.itemID)"
    }

    private func entries() -> [String: Item] {
        if let loaded { return loaded }
        let result = readFile()
        loaded = result
        return result
    }

    private func readFile() -> [String: Item] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            lastLoadFailureDescription = "读取隐藏列表失败:\(error)"
            Self.logger.error("隐藏列表读取失败 \(String(describing: error), privacy: .public)")
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: Item].self, from: data)
        } catch {
            // ⛔ 不就地重置成空文件 —— 先如实记下原因
            lastLoadFailureDescription = "隐藏列表文件损坏:\(error)"
            Self.logger.error("隐藏列表文件损坏 \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func persist(_ entries: [String: Item]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(fileURL.lastPathComponent).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw HiddenItemsStoreError.writeFailed
        }
        // 0600:「谁不想看什么」属于隐私,不该对同机其他用户可读
        guard FileManager.default.createFile(
            atPath: temporary.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw HiddenItemsStoreError.writeFailed
        }
        guard rename(temporary.path(percentEncoded: false), fileURL.path(percentEncoded: false)) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw HiddenItemsStoreError.writeFailed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = fileURL
        try target.setResourceValues(values)
        loaded = entries
    }
}

/// 隐藏列表写不进去。
///
/// ⚠️ 与 `WatchProgressStoreError` 分开:写入失败要能说清是**哪个**本地库出的事,
/// 合并成一个枚举会让「续播库坏了」与「隐藏列表坏了」混成一句。
enum HiddenItemsStoreError: LocalizedError, Sendable, Equatable {
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .writeFailed: return "隐藏列表写入失败"
        }
    }
}
