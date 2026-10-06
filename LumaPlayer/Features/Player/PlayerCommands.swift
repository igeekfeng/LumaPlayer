import SwiftUI

extension FocusedValues {
    /// 当前处于前台的播放页。只有播放窗口是 key window 时才有值,
    /// 菜单项据此启用 / 禁用 —— 主窗口里按空格不会去暂停后台的播放器。
    @Entry var playerViewModel: PlayerViewModel?
}

/// 菜单栏「播放」菜单(播放快捷键和菜单)。
///
/// 快捷键与 `PlayerWindowView` 的按键处理一致(UI_DESIGN.md 5.3)。
/// 方向键 seek 不挂在菜单上:菜单快捷键按住会连发,而转码模式下
/// 每次 seek 都是一次重新起流;方向键只在视图里按 `.down` 处理。
struct PlayerCommands: Commands {
    @FocusedValue(\.playerViewModel) private var player

    var body: some Commands {
        CommandMenu("播放") {
            Button(player?.isPaused == false ? "暂停" : "播放") {
                player?.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player?.session == nil)

            Divider()

            Button("后退 \(Int(Metrics.seekStep)) 秒") { player?.skip(by: -Metrics.seekStep) }
                .disabled(player?.session == nil)
            Button("前进 \(Int(Metrics.seekStep)) 秒") { player?.skip(by: Metrics.seekStep) }
                .disabled(player?.session == nil)

            Divider()

            Button("加快") { player?.stepSpeed(up: true) }
                .keyboardShortcut("]", modifiers: [])
                .disabled(player?.session == nil)
            Button("减慢") { player?.stepSpeed(up: false) }
                .keyboardShortcut("[", modifiers: [])
                .disabled(player?.session == nil)
            Button("正常速度") { player?.setSpeed(1) }
                .keyboardShortcut("\\", modifiers: [])
                .disabled(player?.session == nil)

            Divider()

            Button("调高音量") { player?.adjustVolume(by: Metrics.volumeStep) }
                .disabled(player?.session == nil)
            Button("调低音量") { player?.adjustVolume(by: -Metrics.volumeStep) }
                .disabled(player?.session == nil)
            Button(player?.isMuted == true ? "取消静音" : "静音") { player?.toggleMute() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(player?.session == nil)

            Divider()

            subtitleMenu
            subtitleDelayMenu
            audioMenu

            Divider()

            Button("跳过片头") { player?.skipIntro() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(player?.isSkipIntroAvailable != true)
            Button("上一集") { player?.playPreviousEpisode() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player?.previousEpisode == nil)
            Button("下一集") { player?.playNextEpisode() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player?.nextEpisode == nil)

            Divider()

            preferenceToggles
        }
    }

    /// 没有播放页时显示为禁用的占位项,菜单结构不跳动
    @ViewBuilder
    private var preferenceToggles: some View {
        if let player {
            @Bindable var player = player
            Toggle("自动跳过片头", isOn: $player.autoSkipIntro)
            Toggle("自动播放下一集", isOn: $player.autoPlayNext)
            Toggle("窗口置顶", isOn: $player.floatsOnTop)
                .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("显示统计信息", isOn: Binding(
                get: { player.showsStatistics },
                set: { _ in player.toggleStatistics() }
            ))
            .keyboardShortcut("i", modifiers: [])
        } else {
            Toggle("自动跳过片头", isOn: .constant(false)).disabled(true)
            Toggle("自动播放下一集", isOn: .constant(false)).disabled(true)
            Toggle("窗口置顶", isOn: .constant(false)).disabled(true)
            Toggle("显示统计信息", isOn: .constant(false)).disabled(true)
        }
    }

    @ViewBuilder
    private var subtitleMenu: some View {
        if let player, !player.subtitleTracks.isEmpty {
            Picker("字幕", selection: Binding<Int?>(
                get: { player.selectedSubtitleTrackID },
                set: { player.selectSubtitleTrack($0) }
            )) {
                Text("关闭").tag(Int?.none)
                ForEach(player.subtitleTracks) { track in
                    Text(track.displayName).tag(Int?.some(track.id))
                }
            }
        } else {
            Menu("字幕") {}.disabled(true)
        }
    }

    /// Z / X 提前 / 延后 0.1 秒,⇧ 为 1 秒(与 mpv 默认键位一致,UI_DESIGN.md 5.3)。
    /// 按住会连发 —— 和方向键 seek 不同,改 `sub-delay` 是纯本地操作,没有请求开销。
    @ViewBuilder
    private var subtitleDelayMenu: some View {
        if let player {
            Menu("字幕延迟:\(PlayerViewModel.subtitleDelayValueText(player.subtitleDelay))") {
                PlayerSubtitleDelayButtons(viewModel: player, withShortcuts: true)
            }
            .disabled(!player.canAdjustSubtitleDelay)
        } else {
            Menu("字幕延迟") {}.disabled(true)
        }
    }

    @ViewBuilder
    private var audioMenu: some View {
        if let player, !player.audioTracks.isEmpty {
            Picker("音轨", selection: Binding<Int?>(
                get: { player.selectedAudioTrackID },
                set: { id in if let id { player.selectAudioTrack(id) } }
            )) {
                ForEach(player.audioTracks) { track in
                    Text(track.displayName).tag(Int?.some(track.id))
                }
            }
        } else {
            Menu("音轨") {}.disabled(true)
        }
    }
}
