import AppKit
import MediaPlayer

/// 接入系统「正在播放」(控制中心 / 锁屏)与媒体键。
///
/// 只在播放页存活期间注册,关窗全部撤销,否则媒体键会派给已不存在的会话。
/// 进度只在状态变化时写入:系统按 `playbackRate` 自己外推。
@MainActor
final class NowPlayingController {
    private weak var viewModel: PlayerViewModel?
    private var targets: [(MPRemoteCommand, Any)] = []
    /// nil 时系统显示默认图标
    private var artwork: MPMediaItemArtwork?

    func setArtwork(_ image: NSImage) {
        artwork = Self.makeArtwork(image)
    }

    /// ⛔ 必须 nonisolated:`requestHandler` 在 MediaPlayer 自己的队列上调用,
    /// 闭包若继承 MainActor 隔离,运行时隔离检查会直接 trap。
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
            MPMediaItemPropertyTitle: item.map { emby in
                emby.kind == .episode
                    ? [emby.episodeLabel, emby.name].compactMap { $0 }.joined(separator: " · ")
                    : emby.name
            } ?? viewModel.playingTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: viewModel.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: viewModel.isPaused || viewModel.isEnded ? 0 : viewModel.speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let series = item?.seriesName {
            info[MPMediaItemPropertyArtist] = series
        }
        if viewModel.durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = viewModel.durationSeconds
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        // 上一曲 / 下一曲 = 上一集 / 下一集;没有时置灰
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

        // 跳转间隔注册时读一次设置页步长;改了要下次起播才同步
        let step = viewModel?.seekStep ?? Metrics.seekStep
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: step)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: step)]
        add(commands.skipForwardCommand) { $0.skip(by: $0.seekStep) }
        add(commands.skipBackwardCommand) { $0.skip(by: -$0.seekStep) }

        add(commands.nextTrackCommand) { $0.playNextEpisode() }
        add(commands.previousTrackCommand) { $0.playPreviousEpisode() }

        // 系统倍速命令只支持离散档位
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

    /// 远程命令在主线程回调,故可 `assumeIsolated`;不在主线程时宁可崩,不悄悄数据竞争。
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
