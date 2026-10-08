import AppKit
import MediaPlayer

/// 接入系统「正在播放」(控制中心 / 锁屏小组件)与键盘媒体键(F7–F9、耳机线控)。
///
/// 这是 macOS 原生播放器相对网页端的优势之一:播放窗口不在前台时,
/// 仍能用媒体键暂停、跳转。只在播放页存活期间注册,关窗即全部撤销 ——
/// 否则关掉播放器后按媒体键,系统仍会把事件派给一个已经不存在的会话。
///
/// 进度只在状态变化(暂停 / 倍速 / 时长 / 定期校准)时写入:
/// 系统会按 `playbackRate` 自己外推,不需要跟着每 0.2s 的 time-pos 刷新。
@MainActor
final class NowPlayingController {
    private weak var viewModel: PlayerViewModel?
    private var targets: [(MPRemoteCommand, Any)] = []
    /// 封面(剧照 / 海报),由播放页取到图后设置;没有就不带,系统显示默认图标
    private var artwork: MPMediaItemArtwork?

    func setArtwork(_ image: NSImage) {
        artwork = Self.makeArtwork(image)
    }

    /// `requestHandler` 由 MediaPlayer 在它自己的 accessQueue 上调用,不在主线程。
    /// 闭包若写在本类(`@MainActor`)的方法里会继承主线程隔离,被调时 Swift 运行时
    /// 隔离检查直接 trap(EXC_BREAKPOINT)—— 所以必须在 nonisolated 上下文里创建。
    nonisolated static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func update(from viewModel: PlayerViewModel) {
        if self.viewModel !== viewModel {
            deactivate()
            self.viewModel = viewModel
            registerCommands()
        }
        let item = viewModel.playingItem
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.kind == .episode
                ? [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
                : item.name,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: viewModel.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: viewModel.isPaused || viewModel.isEnded ? 0 : viewModel.speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let series = item.seriesName {
            info[MPMediaItemPropertyArtist] = series
        }
        if viewModel.durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = viewModel.durationSeconds
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        // 上一曲 / 下一曲 = 上一集 / 下一集;没有时置灰,而不是按了没反应
        let commands = MPRemoteCommandCenter.shared()
        commands.previousTrackCommand.isEnabled = viewModel.previousEpisode != nil
        commands.nextTrackCommand.isEnabled = viewModel.nextEpisode != nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // macOS 上系统靠 playbackState(而不是 rate)判断当前是否在播
        center.playbackState = viewModel.isEnded ? .stopped : (viewModel.isPaused ? .paused : .playing)
    }

    func deactivate() {
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets.removeAll()
        artwork = nil
        guard viewModel != nil else { return }
        viewModel = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func registerCommands() {
        let commands = MPRemoteCommandCenter.shared()
        add(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        add(commands.playCommand) { if $0.isPaused { $0.togglePlayPause() } }
        add(commands.pauseCommand) { if !$0.isPaused { $0.togglePlayPause() } }

        // 系统「正在播放」的跳转间隔跟着设置页的步长走(注册时读一次;改了步长
        // 要下一次起播才同步 —— 这是低频偏好,不值得为它拆一遍命令注册)。
        let step = viewModel?.seekStep ?? Metrics.seekStep
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: step)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: step)]
        add(commands.skipForwardCommand) { $0.skip(by: $0.seekStep) }
        add(commands.skipBackwardCommand) { $0.skip(by: -$0.seekStep) }

        add(commands.nextTrackCommand) { $0.playNextEpisode() }
        add(commands.previousTrackCommand) { $0.playPreviousEpisode() }

        // 控制中心里的倍速:系统这条命令只能给离散档位(播放器内是连续滑块),
        // 所以给一组覆盖常用区间的档位
        let rate = commands.changePlaybackRateCommand
        rate.supportedPlaybackRates = PlayerViewModel.speedPresets.map { NSNumber(value: $0) }
        let rateTarget = rate.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let value = Double(event.playbackRate)
            return MainActor.assumeIsolated {
                guard let viewModel = self?.viewModel else { return .noActionableNowPlayingItem }
                viewModel.setSpeed(value)
                return .success
            }
        }
        targets.append((rate, rateTarget))

        let seek = commands.changePlaybackPositionCommand
        let target = seek.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return MainActor.assumeIsolated {
                guard let viewModel = self?.viewModel else { return .noActionableNowPlayingItem }
                viewModel.seek(to: position)
                return .success
            }
        }
        targets.append((seek, target))
    }

    /// 系统在主线程回调远程命令(MPRemoteCommand 文档),所以这里可以
    /// `assumeIsolated` 回到 MainActor;若哪天不在主线程,它会直接崩在这里,
    /// 而不是悄悄数据竞争。
    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerViewModel) -> Void) {
        let target = command.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let viewModel = self?.viewModel else { return .noActionableNowPlayingItem }
                action(viewModel)
                return .success
            }
        }
        targets.append((command, target))
    }
}
