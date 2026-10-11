import Foundation

/// mpv 渲染后端(render.h 的 `MPV_RENDER_PARAM_BACKEND`)。
///
/// - `gpuNext`:libplacebo,能正确处理 Dolby Vision(Profile 5)/ HDR;
///   代价是 GPU 负载明显高于 legacy(`KNOWN_ISSUES.md` Q42)。
/// - `legacy`:mpv 默认的 `gpu` 渲染器(不传 BACKEND 参数),不处理 DV 的 RPU,
///   DV Profile 5 会发紫发绿;HDR10 / HLG 有它自己的色调映射,颜色是对的。
///
/// `rawValue` 即统计里 `renderBackend` 记的名字。
enum MPVRenderBackend: String, Sendable, Equatable {
    case gpuNext = "gpu-next"
    case legacy = "gpu"
}

/// 渲染后端策略(设置 →「播放 → 色彩」)。默认 `automatic`。
///
/// 为什么默认按片源选、而不是一律 gpu-next:需要 gpu-next 的只有少数 DV 片源,
/// 一律开着等于让所有 SDR / HDR10 片子都多付几倍 GPU 能耗。
///
/// 「按片源」的判据来自 **mpv 自己** demux 出的 `track-list/N/dolby-vision-profile`,
/// 不用 Emby 的 MediaStream 字段 —— 那些字段未在 `API_CONTRACT.md` 核实(CLAUDE.md 硬规则 1)。
/// 时机是 `on_preloaded` hook:轨道已知、VO 还没建,此时换后端不需要重开流
/// (见 `MPVPlayer.handlePreloadedHook`)。
enum MPVRenderBackendPolicy: String, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }

    /// 先建 legacy;demux 出 DV 配置记录时在 VO 建立前换成 gpu-next
    case automatic
    /// 一律 gpu-next(旧版「杜比视界 / HDR 兼容渲染」开着的行为)
    case gpuNext
    /// 一律 legacy(gpu-next 走的是上游未合并的 draft PR,万一让别的片源出问题时的退路)
    case legacy

    /// GL 上下文挂上时先建的后端。`automatic` 先建省电的 legacy,
    /// 因为这时还不知道片源是什么。
    var initialBackend: MPVRenderBackend {
        self == .gpuNext ? .gpuNext : .legacy
    }

    /// 文件的轨道已知后应使用的后端。
    ///
    /// `automatic` 只看「有没有带 DV 配置记录的真视频轨」(封面图不算);
    /// HDR10 / HLG 不切 —— legacy 处理得了,切过去只是多耗电。
    /// 此时 mpv 还没选轨(`on_preloaded` 在选轨之前),所以看的是全部视频轨。
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

    /// 设置页显示名
    var label: String {
        switch self {
        case .automatic: "自动(按片源)"
        case .gpuNext: "始终 gpu-next"
        case .legacy: "始终旧渲染器"
        }
    }

    /// 设置页 footer 里的一句解释
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
