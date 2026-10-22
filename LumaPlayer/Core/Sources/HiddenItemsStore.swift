import Foundation
import os

/// 本地「隐藏条目」库:条目从列表 / 换集队列 / 续播区消失,⛔ 不动源文件(文件树来源没有服务端标记接口)。
/// 可在设置页「已隐藏」恢复。连源文件一起删时⛔ 不写这里(恢复不出东西)。
///
/// 隐藏目录时其下各集的续播卡片也要消失,靠 `hiddenPaths` 过滤(卡片记的是集文件 id)。
/// 落点与凭据文件同级。
actor HiddenItemsStore {

    /// 只存恢复、展示与路径过滤要的字段,⛔ 不多存(多一份就多一处不同步)。
    struct Item: Codable, Sendable, Equatable, Identifiable {
        let ref: SourceItemRef
        /// 隐藏那一刻的标题(设置页显示用)
        let title: String
        let hiddenAt: Date
        /// 隐藏那一刻的来源内路径,用于连带滤掉目录里各集的续播卡片。
        /// 旧格式记录没有这一格(nil),只按 `ref` 过滤。
        var path: String? = nil
        /// 旧格式记录按单条文件处理(只认路径完全相等)。
        var isDirectory: Bool = false

        /// 与存储键同形
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

        /// ⚠️ 手写解码:合成实现对非可选 `Bool` 走 `decode`,旧文件缺键会整份解码失败、隐藏列表全丢。
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ref = try container.decode(SourceItemRef.self, forKey: .ref)
            title = try container.decode(String.self, forKey: .title)
            hiddenAt = try container.decode(Date.self, forKey: .hiddenAt)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        }
    }

    /// 续播卡片的过滤规则。
    struct HiddenPath: Sendable, Equatable {
        let path: String
        let isDirectory: Bool
    }

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "hidden-items")

    private let fileURL: URL
    private var loaded: [String: Item]?
    /// 读盘失败的原因,由调用方决定要不要提示。
    private(set) var lastLoadFailureDescription: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// ⚠️ 测试宿主用另一个文件名:单测跑在宿主 App 进程里、共享真实沙盒容器。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let filename = isTestHost ? "hidden-items-testhost.json" : "hidden-items.json"
        return CredentialFileStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: filename, directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 视图层拿它做同步过滤(计算属性里不能 await)。
    func hiddenRefs(sourceID: UUID) -> Set<SourceItemRef> {
        Set(entries().values.filter { $0.ref.sourceID == sourceID }.map(\.ref))
    }

    /// 续播卡片的过滤用(`hiddenRefs` 挡不住隐藏目录下的集文件)。没有 `path` 的记录不出现在这里。
    func hiddenPaths(sourceID: UUID) -> [HiddenPath] {
        entries().values
            .filter { $0.ref.sourceID == sourceID }
            .compactMap { item in
                guard let path = item.path, !path.isEmpty else { return nil }
                return HiddenPath(path: path, isDirectory: item.isDirectory)
            }
    }

    /// 最近隐藏的在前。
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

    /// 条目本身还在,下次列目录就会回来。
    func restore(_ ref: SourceItemRef) throws {
        var current = entries()
        guard current.removeValue(forKey: Self.key(for: ref)) != nil else { return }
        try persist(current)
    }

    /// ⚠️ 只给本地文件夹来源用(条目 id 只在该来源内有意义)。
    /// ⛔ 百度来源不清:共用一份授权,删来源不等于文件不在了。
    func purge(sourceID: UUID) throws {
        var current = entries()
        let before = current.count
        current = current.filter { $0.value.ref.sourceID != sourceID }
        guard current.count != before else { return }
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
            // ⛔ 不就地重置成空文件
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
        // 0600:属隐私
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

/// 与 `WatchProgressStoreError` 分开,写入失败才说得清是哪个本地库出的事。
enum HiddenItemsStoreError: LocalizedError, Sendable, Equatable {
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .writeFailed: return "隐藏列表写入失败"
        }
    }
}
