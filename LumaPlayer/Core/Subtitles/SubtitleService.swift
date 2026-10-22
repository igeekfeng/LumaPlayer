import Foundation
import os

/// 在线字幕搜索结果(来源无关)。UI 只认它,⛔ 不认 assrt 的 JSON 字段名。
struct SubtitleSearchResult: Sendable, Equatable, Identifiable {
    let id: Int
    let title: String
    /// 字幕对应的视频文件名(帮用户判断版本)
    let videoName: String?
    let language: String?
    let format: String?
    let releaseSite: String?
    let uploadTime: String?
    let voteScore: Int

    /// `语言 · 格式 · 字幕组`,空项跳过;全空返回 nil。
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

/// 在线字幕编排:凭据 → 搜索 → 挑文件 → 下载 → 落盘。不碰 mpv(挂载在 `PlayerViewModel`),不碰 UI。
///
/// 目前只有 assrt 一个来源。⛔ 接第二个站之前不抽 `SubtitleProvider` 协议。
actor SubtitleService {

    /// assrt 要求在合适位置注明来源及链接。
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

    /// 返回可以直接 `sub-add` 的本地文件。
    func download(_ result: SubtitleSearchResult) async throws -> SubtitleFileStore.Stored {
        try await download(assrtID: result.id)
    }

    /// 先查本地缓存(命中零请求)→ 详情 → 挑文本文件 → 下载单文件 → 转码落盘。
    /// 单文件下载失败(assrt 服务端解压会坏,见 `SubtitleArchiveExtractor`)时改下整包本地解压,
    /// 优先取同名文件;`filelist` 为空时直接走整包。
    /// ⚠️ 详情里的地址是一次性的,所以缓存的是文件而不是地址。
    func download(assrtID id: Int) async throws -> SubtitleFileStore.Stored {
        let group = Self.cacheGroup(assrtID: id)
        if let cached = try await store.cachedFile(group: group) {
            return cached
        }

        let token = try await requireToken()
        let detail = try await client.detail(id: id, token: token)

        guard let picked = Self.pick(detail.files) else {
            // 有文件却没有文本字幕(只有图形字幕):如实拒绝,整包里也是同一批文件
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

    /// `SubtitleFileStore` 里的组名
    static func cacheGroup(assrtID: Int) -> String { "assrt-\(assrtID)" }

    /// 有与 `preferredFileName` 同名的就取它,没有就按格式优先级挑。
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

    /// 按 `SubtitleFormats.downloadableOrder` 挑一条能挂的文本字幕(⛔ 不收 `.sub`,理由见那里)。
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
