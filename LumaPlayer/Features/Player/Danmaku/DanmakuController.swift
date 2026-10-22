import CoreText
import Foundation
import Observation

/// 这一集的弹幕状态(每个 `PlayerViewModel` 一份)。⛔ 不碰网络细节与凭据(在 `DanmakuService`)。
///
/// 弹幕时间 = 视频时间 − `shift`;`shift` = 弹弹play 偏移 + 用户偏移,正数表示弹幕延后
/// (同 `/match` 的 `shift`,`docs/DANDANPLAY_API.md` §2)。
@MainActor
@Observable
final class DanmakuController {

    enum Status: Equatable {
        /// 本集没开弹幕(用户关了,且还没请求过)
        case off
        case loading
        case loaded(count: Int, droppedCount: Int, title: String)
        /// 没能自动确定弹幕库,等用户挑(`candidates` 可为空 → 只能搜)
        case needsSelection(candidates: [DanmakuCandidate])
        case failed(message: String, needsCredentials: Bool)
    }

    private(set) var status: Status = .off
    /// 会话级开关,初值取设置里的「自动加载」
    private(set) var isVisible: Bool
    /// 秒,本集有效
    var userOffset: Double = 0

    let query: DanmakuMediaQuery
    @ObservationIgnored private let service: DanmakuService
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    // 以下三个 provider 由 `PlayerViewModel` 接上
    /// 秒,给 `/match` 的 `videoDuration`
    @ObservationIgnored var durationProvider: () -> Double? = { nil }
    /// `DanmakuMatchContext.fileHash`;nil = 算不出来,退回文件名匹配
    @ObservationIgnored var fingerprintProvider: () async -> String? = { nil }
    @ObservationIgnored var matchHintsProvider: () -> DanmakuMatchHints = { .none }

    /// 与 `widthPerPoint`(1pt 字号下的宽度)一一对应
    private(set) var loaded: LoadedDanmaku?
    private(set) var widthPerPoint: [CGFloat] = []

    init(query: DanmakuMediaQuery, service: DanmakuService, enabledByDefault: Bool) {
        self.query = query
        self.service = service
        self.isVisible = enabledByDefault
    }

    var shift: Double { (loaded?.binding.shift ?? 0) + userOffset }

    // MARK: - 生命周期

    /// 开着且还没请求过才发起(转码重新起流 / 重试也会调到这里)。
    func startIfNeeded() {
        guard isVisible, status == .off else { return }
        reload()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { startIfNeeded() }
    }

    /// 重新自动匹配。指纹在这里取(要等播放源就绪);取不到就退回文件名匹配,⛔ 指纹不是匹配前提。
    func reload() {
        loadTask?.cancel()
        status = .loading
        let query = query
        let duration = durationProvider()
        let hints = matchHintsProvider()
        let fingerprintProvider = self.fingerprintProvider
        loadTask = Task { [weak self, service] in
            do {
                let fingerprint = await fingerprintProvider()
                guard !Task.isCancelled else { return }
                let context = DanmakuMatchContext(
                    tmdbID: hints.tmdbID ?? query.tmdbID,
                    isMovie: hints.isMovie ?? query.isMovie,
                    fileHash: fingerprint)
                let resolution = try await service.resolve(
                    query, durationSeconds: duration, matchContext: context)
                guard !Task.isCancelled else { return }
                switch resolution {
                case .loaded(let danmaku): await self?.apply(danmaku)
                case .needsSelection(let candidates): self?.status = .needsSelection(candidates: candidates)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.fail(error)
            }
        }
    }

    func select(_ candidate: DanmakuCandidate) {
        loadTask?.cancel()
        status = .loading
        isVisible = true
        let query = query
        loadTask = Task { [weak self, service] in
            do {
                let danmaku = try await service.select(candidate, for: query)
                guard !Task.isCancelled else { return }
                await self?.apply(danmaku)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.fail(error)
            }
        }
    }

    func search(keyword: String, episode: Int?) async throws -> (groups: [DanmakuSearchGroup], hasMore: Bool) {
        try await service.search(keyword: keyword, episode: episode)
    }

    /// 「匹配错了」:忘掉绑定、清空弹幕,回到等用户挑。
    func unbind() async throws {
        loadTask?.cancel()
        try await service.unbind(query)
        loaded = nil
        widthPerPoint = []
        layoutMemo = nil
        status = .needsSelection(candidates: [])
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - 排版缓存

    @ObservationIgnored private var layoutMemo: (parameters: DanmakuLayout.Parameters, placed: [PlacedDanmaku], maxLifetime: Double)?

    /// 每重排一次 +1。渲染层按下标缓存位图,代号变了须整批丢弃。
    @ObservationIgnored private(set) var layoutGeneration = 0

    /// 参数不变时返回缓存(渲染层每帧都会问)。
    func placement(for parameters: DanmakuLayout.Parameters) -> (placed: [PlacedDanmaku], maxLifetime: Double) {
        if let memo = layoutMemo, memo.parameters == parameters {
            return (memo.placed, memo.maxLifetime)
        }
        guard let loaded, loaded.comments.count == widthPerPoint.count else { return ([], 0) }
        let placed = DanmakuLayout.layout(loaded.comments, widthPerPoint: widthPerPoint, parameters: parameters)
        let lifetime = DanmakuLayout.maxLifetime(of: placed)
        layoutMemo = (parameters, placed, lifetime)
        layoutGeneration += 1
        return (placed, lifetime)
    }

    // MARK: - 内部

    private func apply(_ danmaku: LoadedDanmaku) async {
        let texts = danmaku.comments.map(\.text)
        // 上万条的测量放到后台:CoreText 的测量是线程安全的
        let widths = await Task.detached(priority: .userInitiated) {
            Self.measure(texts)
        }.value
        guard !Task.isCancelled else { return }
        loaded = danmaku
        widthPerPoint = widths
        layoutMemo = nil
        let binding = danmaku.binding
        let title = [binding.animeTitle, binding.episodeTitle].compactMap { $0 }.joined(separator: " · ")
        status = .loaded(
            count: danmaku.comments.count, droppedCount: danmaku.droppedCount,
            title: title.isEmpty ? "弹幕库 \(binding.episodeID)" : title)
    }

    private func fail(_ error: any Error) {
        switch error {
        case let error as DandanplayError:
            status = .failed(message: error.userMessage, needsCredentials: error.needsCredentials)
        case let error as LocalizedError:
            status = .failed(message: error.errorDescription ?? "加载弹幕失败", needsCredentials: false)
        default:
            status = .failed(message: "加载弹幕失败:\(error.localizedDescription)", needsCredentials: false)
        }
    }

    /// 在 100pt 下测再除以 100,比直接测 1pt 精确。
    private nonisolated static let measureFontSize: CGFloat = 100

    /// 每条文字在 1pt 字号下的宽度。⛔ 字体须与 `DanmakuSprite.font` 一致。
    nonisolated static func measure(_ texts: [String]) -> [CGFloat] {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, measureFontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, measureFontSize, nil)
        return texts.map { text in
            let attributed = NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / measureFontSize
        }
    }
}
