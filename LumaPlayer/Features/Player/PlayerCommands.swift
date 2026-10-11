import SwiftUI

extension FocusedValues {
    /// 当前处于前台的播放页。只有播放窗口是 key window 时才有值,
    /// 菜单项据此启用 / 禁用 —— 主窗口里按空格不会去暂停后台的播放器。
    @Entry var playerViewModel: PlayerViewModel?
}

/// 菜单栏「Playback」菜单(播放快捷键和菜单)。
///
/// 文案用英文:App 只声明了 en,系统自带的 File / Edit / View… 都是英文,
/// 这里跟着它们,菜单栏不中英混排。App 内的界面仍是中文。
///
/// ## 快捷键表(改键时这里、`PlayerWindowView` 的按键处理、菜单三处一起改)
///
/// | 操作 | 键 |
/// |---|---|
/// | 播放 / 暂停 | Space,或单击画面 |
/// | 后退 / 前进(`seekStep`,设置页可改) | ← / → |
/// | 大步后退 / 前进(`seekStepLarge`) | ⇧← / ⇧→ |
/// | 音量 ± `volumeStep`(同时解除静音) | ↑ / ↓ |
/// | 静音 | M |
/// | 加快 / 减慢 / 正常速度(0.25–4×,步长 0.1) | ] / [ / \ |
/// | 上一集 / 下一集 | ⌘← / ⌘→ |
/// | 跳过片头(只在片头区间内生效) | S |
/// | 统计信息 | I |
/// | 窗口置顶 | ⌥⌘T |
/// | 全屏 | F,或双击画面 |
/// | 退出全屏 | Esc |
/// | 拖进度 | 触控板双指横滑(松手才 seek,纵向不拦截) |
///
/// (旧内核的 Z / X 字幕延迟随换 Erika 移除:Erika 没有这项能力。)
/// 方向键 seek ⛔ 不挂在菜单上:菜单快捷键按住会连发,而转码模式下
/// 每次 seek 都是一次重新起流;方向键只在视图里按 `.down` 处理。
struct PlayerCommands: Commands {
    @FocusedValue(\.playerViewModel) private var player

    /// 没有播放页时用默认步长(设置页改了也只影响下一次播放的菜单文案)
    private var seekStep: Double { player?.seekStep ?? Metrics.seekStep }

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player?.isPaused == false ? "Pause" : "Play") {
                player?.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player?.session == nil)

            Divider()

            Button("Skip Back \(Int(seekStep)) Seconds") { player?.skip(by: -seekStep) }
                .disabled(player?.session == nil)
            Button("Skip Forward \(Int(seekStep)) Seconds") { player?.skip(by: seekStep) }
                .disabled(player?.session == nil)

            Divider()

            Button("Speed Up") { player?.stepSpeed(up: true) }
                .keyboardShortcut("]", modifiers: [])
                .disabled(player?.session == nil)
            Button("Slow Down") { player?.stepSpeed(up: false) }
                .keyboardShortcut("[", modifiers: [])
                .disabled(player?.session == nil)
            Button("Normal Speed") { player?.setSpeed(1) }
                .keyboardShortcut("\\", modifiers: [])
                .disabled(player?.session == nil)

            Divider()

            Button("Volume Up") { player?.adjustVolume(by: Metrics.volumeStep) }
                .disabled(player?.session == nil)
            Button("Volume Down") { player?.adjustVolume(by: -Metrics.volumeStep) }
                .disabled(player?.session == nil)
            Button(player?.isMuted == true ? "Unmute" : "Mute") { player?.toggleMute() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(player?.session == nil)

            Divider()

            subtitleMenu
            audioMenu

            Divider()

            Button("Skip Intro") { player?.skipIntro() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(player?.isSkipIntroAvailable != true)
            Button("Previous Episode") { player?.playPreviousEpisode() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player?.previousEpisode == nil)
            Button("Next Episode") { player?.playNextEpisode() }
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
            Toggle("Skip Intro Automatically", isOn: $player.autoSkipIntro)
            Toggle("Play Next Episode Automatically", isOn: $player.autoPlayNext)
            Toggle("Float on Top", isOn: $player.floatsOnTop)
                .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("Show Statistics", isOn: Binding(
                get: { player.showsStatistics },
                set: { _ in player.toggleStatistics() }
            ))
            .keyboardShortcut("i", modifiers: [])
        } else {
            Toggle("Skip Intro Automatically", isOn: .constant(false)).disabled(true)
            Toggle("Play Next Episode Automatically", isOn: .constant(false)).disabled(true)
            Toggle("Float on Top", isOn: .constant(false)).disabled(true)
            Toggle("Show Statistics", isOn: .constant(false)).disabled(true)
        }
    }

    @ViewBuilder
    private var subtitleMenu: some View {
        if let player, !player.subtitleTracks.isEmpty {
            Picker("Subtitles", selection: Binding<Int64?>(
                get: { player.selectedSubtitleTrackID },
                set: { player.selectSubtitleTrack($0) }
            )) {
                Text("Off").tag(Int64?.none)
                ForEach(player.subtitleTracks) { track in
                    Text(track.displayName).tag(Int64?.some(track.id))
                }
            }
        } else {
            Menu("Subtitles") {}.disabled(true)
        }
    }

    @ViewBuilder
    private var audioMenu: some View {
        if let player, !player.audioTracks.isEmpty {
            Picker("Audio", selection: Binding<Int64?>(
                get: { player.selectedAudioTrackID },
                set: { id in if let id { player.selectAudioTrack(id) } }
            )) {
                ForEach(player.audioTracks) { track in
                    Text(track.displayName).tag(Int64?.some(track.id))
                }
            }
        } else {
            Menu("Audio") {}.disabled(true)
        }
    }
}
