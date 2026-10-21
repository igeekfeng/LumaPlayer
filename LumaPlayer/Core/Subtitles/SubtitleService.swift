import Foundation
import os

/// 一条**在线字幕**的搜索结果(来源无关的形态)。
///
/// UI 只认它,⛔ 不认 assrt 的 JSON 字段名 —— 以后换 / 加字幕站时,
/// 改的是 `SubtitleService` 的映射,不是面板。
struct SubtitleSearchResult: Sendable, Equatable, Identifiable {
    let id: Int
    let title: String
    /// 字幕对应的视频文件名(帮用户判断是不是自己这一版)
    let videoName: String?
    let language: String?
    let format: String?
    let releaseSite: String?
    let uploadTime: String?
    let voteScore: Int

    /// 副标题行:`语言 · 格式 · 字幕组`,空项跳过;全空返回 nil(不显示空括号)。
    var detailLine: String? {
        let parts = [language, format, releaseSite].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension SubtitleSearchResult {
    init(_ assrt: AssrtSearchResult) {
        self.init(
            id: assrt.id,
            title: assrt.title,
            videoName: assrt.videoName,
            language: assrt.language,
            format: assrt.format,
            releaseSite: assrt.releaseSite,
            uploadTime: assrt.uploadTime,
            voteScore: assrt.voteScore)
    }
}

/// 在线字幕的编排层:凭据 → 搜索 → 挑文件 → 下载 → 落盘。
///
/// 目前只有 **assrt(伪射手)** 一个来源。⛔ 现在不抽 `SubtitleProvider` 协议:
/// 一个实现撑不起协议,等真的接第二个站(OpenSubtitles 之类)时按两个真实差异再抽,
/// 免得先编一层谁都不合身的抽象。
///
/// 职责边界:不碰 mpv(挂载在 `PlayerViewModel`),不碰 UI。
actor SubtitleService {

    /// assrt 的归因要求(文档原话:请在合适的位置添加来源说明及本站链接)。
    static let attribution = "字幕服务由 assrt.net 提供"
    static let attributionURL = URL(string: "https://assrt.net")!

    private let credentials: CredentialStore
    private let client: AssrtClient
    private let store: SubtitleFileStore

    init(credentials: CredentialStore, store: SubtitleFileStore, client: AssrtClient = AssrtClient()) {
        self.credentials = credentials
        self.store = store
        self.client = client
    }

    private static let logger = Logger(subsystem: NetworkDiagnostics.subsystem, category: "subtitles")

    // MARK: - 搜索

    func search(keyword: String) async throws -> [SubtitleSearchResult] {
        let token = try await requireToken()
        return try await client.search(keyword: keyword, token: token)
            .map(SubtitleSearchResult.init)
    }

    // MARK: - 下载

    /// 取一条字幕并落进容器,返回可以直接 `sub-add` 的本地文件。
    func download(_ result: SubtitleSearchResult) async throws -> SubtitleFileStore.Stored {
        try await download(assrtID: result.id)
    }

    /// 按 assrt 字幕 id 取一条字幕(自动挂上次用的字幕、缓存被清掉时也走这里)。
    ///
    /// 顺序:**先查本地缓存**(命中就零请求)→ 详情 → 挑文本文件 → 下载单文件 → 转码落盘。
    /// 单文件下载失败(assrt 的服务端解压会坏,见 `SubtitleArchiveExtractor`)时,
    /// 改下同一次详情里的**整包**、本地解压,优先取同名的那个文件;
    /// `filelist` 为空、只有整包时直接走整包。
    /// ⚠️ 详情里的地址是**一次性**的,所以缓存的是**文件**而不是地址。
    func download(assrtID id: Int) async throws -> SubtitleFileStore.Stored {
        let group = Self.cacheGroup(assrtID: id)
        if let cached = try await store.cachedFile(group: group) {
            return cached
        }

        let token = try await requireToken()
        let detail = try await client.detail(id: id, token: token)

        guard let picked = Self.pick(detail.files) else {
            // 列表里有文件却没有文本字幕(只有图形字幕):如实拒绝,⛔ 不偷偷下载一个挂不上的东西。
            // 整包里装的也是同一批文件,不必再下。
            guard detail.files.isEmpty, let archiveURL = detail.archiveURL else {
                throw AssrtError.noTextFile
            }
            return try await downloadFromArchive(archiveURL, preferredFileName: nil, group: group)
        }

        let data: Data
        do {
            data = try await client.download(picked.file.url)
        } catch {
            guard !(error is CancellationError), let archiveURL = detail.archiveURL else { throw error }
            Self.logger.error("单文件下载失败,改下整包:\(error.localizedDescription, privacy: .public)")
            return try await downloadFromArchive(
                archiveURL, preferredFileName: picked.file.fileName, group: group)
        }
        let stored = try await store.storeDownloaded(
            data: data, fileName: picked.file.fileName, group: group)
        Self.logger.info("在线字幕已落盘 \(picked.file.fileName, privacy: .public)")
        return stored
    }

    /// 一条 assrt 字幕在缓存里的组名(`SubtitleFileStore` 的目录布局)
    static func cacheGroup(assrtID: Int) -> String { "assrt-\(assrtID)" }

    /// 下整包、本地解压、挑一个落盘:包里有与 `preferredFileName` 同名的就取它
    /// (与单文件那条路拿到的是同一份),没有就按格式优先级挑。
    private func downloadFromArchive(
        _ archiveURL: URL, preferredFileName: String?, group: String
    ) async throws -> SubtitleFileStore.Stored {
        let archive = try await client.download(archiveURL)
        let entries = try await SubtitleArchiveExtractor.textSubtitles(in: archive)
        guard let chosen = entries.first(where: { $0.fileName == preferredFileName })
            ?? entries.min(by: { Self.rank($0.fileName) < Self.rank($1.fileName) }) else {
            throw AssrtError.noTextFile
        }
        let stored = try await store.storeDownloaded(
            data: chosen.data, fileName: chosen.fileName, group: group)
        Self.logger.info("在线字幕已从整包解出并落盘 \(chosen.fileName, privacy: .public)")
        return stored
    }

    // MARK: - 细节

    private func requireToken() async throws -> String {
        guard let token = try await credentials.assrtToken(),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssrtError.missingToken
        }
        return token
    }

    /// 从文件列表里挑一条能挂的文本字幕。
    ///
    /// 优先级 `srt > ass > ssa > vtt`(见 `SubtitleFormats.downloadableOrder`)。
    /// ⛔ 在线这一路**不收 `.sub`**:站上的 `.sub` 多半是 VobSub 的配套图形文件
    /// (与 `.idx` 成对),挂上去只会失败;本地导入那条路仍然认它(MicroDVD)。
    ///
    /// `internal` 而非 `private`:单测直接验优先级,不必为了测它去搭一整套下载。
    static func pick(_ files: [AssrtSubtitleFile]) -> (file: AssrtSubtitleFile, index: Int)? {
        let candidates = files.enumerated().filter {
            SubtitleFormats.downloadableOrder.contains(
                ($0.element.fileName as NSString).pathExtension.lowercased())
        }
        return candidates.min { rank($0.element.fileName) < rank($1.element.fileName) }
            .map { (file: $0.element, index: $0.offset) }
    }

    private static func rank(_ fileName: String) -> Int {
        let extensionName = (fileName as NSString).pathExtension.lowercased()
        return SubtitleFormats.downloadableOrder.firstIndex(of: extensionName)
            ?? SubtitleFormats.downloadableOrder.count
    }
}
