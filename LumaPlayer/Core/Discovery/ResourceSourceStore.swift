import Foundation
import os

/// 搜索源清单的存储:JSON 落在 Application Support,与凭据文件同目录。
///
/// 为什么不做成 UserDefaults:这份清单是**用户要维护的数据**(增删源、改地址),
/// 要能导出 / 导入 / 手改;JSON 文件比 UserDefaults 里的二进制 blob 可维护得多。
/// 与 `CredentialFileStore` 一样:原子写、0600、不进备份 —— 清单里虽然没有密码,
/// 但用户可能把带 token 的自建地址写进 `note`,统一按敏感处理更省心。
actor ResourceSourceStore {
    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "resource-sources")

    /// 首次启动的内置源。
    ///
    /// 只放 **Telegram 公开频道**,一个源一个频道 —— 清单小而精,想加/删由用户在设置页改。
    /// ⛔ 不预置 PanSou 实例:那一档会把关键词扇到上百个源,结果杂且依赖别人维护;
    /// 保留 `panSou` 抓取方式,只是默认不给地址。
    ///
    /// 频道选择口径:实测 `?q=` 能返回 20 条、正文是「名称 / 描述 / 网盘链接」格式的,
    /// 且各自侧重不同(综合、夸克、阿里、4K、短剧)。频道会关停,所以这只是**起点**。
    static let builtInSources: [ResourceSource] = [
        ResourceSource(
            id: "tg-tgsearchers7",
            displayName: "资源宇宙7",
            kind: .telegramChannel,
            baseURL: "tgsearchers7",
            note: "综合影视,更新快"),
        ResourceSource(
            id: "tg-Quark_Movies",
            displayName: "Quark Movies",
            kind: .telegramChannel,
            baseURL: "Quark_Movies",
            note: "夸克网盘影视"),
        ResourceSource(
            id: "tg-Aliyun_4K_Movies",
            displayName: "Aliyun 4K Movies",
            kind: .telegramChannel,
            baseURL: "Aliyun_4K_Movies",
            note: "阿里云盘 4K"),
        ResourceSource(
            id: "tg-ucquark",
            displayName: "ucquark",
            kind: .telegramChannel,
            baseURL: "ucquark",
            note: "UC / 夸克"),
        ResourceSource(
            id: "tg-guoman4K",
            displayName: "国漫 4K",
            kind: .telegramChannel,
            baseURL: "guoman4K",
            note: "国漫"),
        ResourceSource(
            id: "tg-kduanju",
            displayName: "短剧",
            kind: .telegramChannel,
            baseURL: "kduanju",
            note: "短剧"),
    ]

    private let fileURL: URL
    private var loaded: [ResourceSource]?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// ⚠️ 测试宿主用另一个文件名:单测跑在宿主 App 进程里、共享真实沙盒容器。
    static var defaultFileURL: URL {
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let name = isTestHost ? "resource-sources-test.json" : "resource-sources.json"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LumaPlayer", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .notDirectory)
    }

    /// 读全部源。文件不存在 = 空清单(不是错误)。
    func sources() async -> [ResourceSource] {
        if let loaded { return loaded }
        let result = load()
        loaded = result
        return result
    }

    func save(_ sources: [ResourceSource]) async throws {
        // 去重:同一个 id 只留第一条(用户在设置页里手改 id 可能撞)
        var seen = Set<String>()
        let deduplicated = sources.filter { seen.insert($0.id).inserted }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(deduplicated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        loaded = deduplicated
    }

    /// 读盘失败的原因,由调用方决定要不要提示。
    func lastLoadFailureDescription() async -> String? {
        _ = await sources()
        return loadFailure
    }

    private var loadFailure: String?

    private func load() -> [ResourceSource] {
        loadFailure = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Self.builtInSources
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([ResourceSource].self, from: data)
        } catch {
            // ⛔ 不静默当成空清单:用户会以为自己的源全丢了。记原因,由设置页显示。
            loadFailure = "读取搜索源清单失败:\(error.localizedDescription)"
            Self.logger.error("读取搜索源清单失败")
            return []
        }
    }
}
