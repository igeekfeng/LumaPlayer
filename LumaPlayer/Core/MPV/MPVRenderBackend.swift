import Foundation

/// mpv 渲染后端(render.h `MPV_RENDER_PARAM_BACKEND`)。`rawValue` 即统计里记的 `renderBackend`。
///
/// - `gpuNext`:libplacebo,正确处理 Dolby Vision Profile 5 / HDR,GPU 负载明显更高(Q42)。
/// - `legacy`:mpv 默认 `gpu`(不传 BACKEND),不处理 DV RPU,DV P5 会发紫发绿;HDR10 / HLG 颜色正确。
enum MPVRenderBackend: String, Sendable, Equatable {
    case gpuNext = "gpu-next"
    case legacy = "gpu"
}

/// 渲染后端策略。默认 `automatic` 按片源选:只有少数 DV 片源需要 gpu-next,一律开着太耗电。
///
/// 判据用 mpv 自己 demux 出的 `track-list/N/dolby-vision-profile`,⛔ 不用 Emby MediaStream 字段
/// (未在 `API_CONTRACT.md` 核实)。在 `on_preloaded` hook 判:轨道已知、VO 未建,换后端不用重开流
/// (`MPVPlayer.handlePreloadedHook`)。
enum MPVRenderBackendPolicy: String, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }

    case automatic
    case gpuNext
    /// gpu-next 来自上游未合并的 draft PR,出问题时的退路
    case legacy

    /// GL 上下文挂上时先建的;此时片源未知,`automatic` 先建省电的 legacy。
    var initialBackend: MPVRenderBackend {
        self == .gpuNext ? .gpuNext : .legacy
    }

    /// `automatic` 只看有没有带 DV 配置记录的真视频轨(封面图不算),HDR10 / HLG 不切。
    /// `on_preloaded` 时 mpv 尚未选轨,所以看全部视频轨。
    func backend(for tracks: [MPVTrack]) -> MPVRenderBackend {
        switch self {
        case .gpuNext: return .gpuNext
        case .legacy: return .legacy
        case .automatic:
            let hasDolbyVision = tracks.contains {
                $0.type == .video && !$0.isAlbumArt && $0.dolbyVisionProfile != nil
            }
            return hasDolbyVision ? .gpuNext : .legacy
        }
    }

    var label: String {
        switch self {
        case .automatic: "自动(按片源)"
        case .gpuNext: "始终 gpu-next"
        case .legacy: "始终旧渲染器"
        }
    }

    /// 设置页 footer
    var detail: String {
        switch self {
        case .automatic:
            "杜比视界片源用 gpu-next(libplacebo),其余片源用省电的旧渲染器。HDR10 / HLG 旧渲染器也能正确显示,不切换。"
        case .gpuNext:
            "所有片源都用 gpu-next:色调映射与缩放画质更好,但 GPU 负载比旧渲染器高很多。"
        case .legacy:
            "所有片源都用旧渲染器:最省电,但杜比视界片源会发紫发绿。只在 gpu-next 让某些片源出问题时才选。"
        }
    }
}
