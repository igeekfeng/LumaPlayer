import XCTest
import OpenGL
import OpenGL.GL3
@testable import LumaPlayer

/// `MPVPlayer` 的渲染后端选择:Dolby Vision 要靠 `gpu-next`(libplacebo),默认按片源选,也可固定。
///
/// 覆盖边界:只验渲染上下文建得起来、请求的后端名,以及自动策略在合成 DV / 非 DV fixture 上让 VO
/// 按哪个后端建起(读 vo_libmpv 日志)。⛔ 验不了画面颜色(需真实 DV 片源目检,Q42)。
/// mpv 不认后端名时会静默退回默认 gpu 且 `mpv_render_context_create` 仍成功,
/// 所以只有读到 `Using gpu-next backend.` 日志的用例才算确证。
final class MPVPlayerRenderBackendTests: XCTestCase {

    /// 离屏 GL3 core context(mpv render API 要求 GL 2.1+ / 3.2 core)。建不出来就 skip(无 GPU 的 CI)。
    private func makeOffscreenContext() throws -> CGLContextObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(kCGLOGLPVersion_GL3_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        guard CGLChoosePixelFormat(attributes, &pixelFormat, &count) == kCGLNoError,
              let pixelFormat else {
            throw XCTSkip("建不出离屏 CGL pixel format,跳过")
        }
        var context: CGLContextObj?
        guard CGLCreateContext(pixelFormat, nil, &context) == kCGLNoError, let context else {
            CGLDestroyPixelFormat(pixelFormat)
            throw XCTSkip("建不出离屏 CGL context,跳过")
        }
        CGLDestroyPixelFormat(pixelFormat)
        return context
    }

    /// shutdown 释放渲染上下文时要用 context,所以先 shutdown 再销毁。mpv init 没成功就 skip。
    private func withPlayer<R>(
        _ policy: MPVRenderBackendPolicy,
        _ body: (MPVPlayer, CGLContextObj) throws -> R
    ) throws -> R {
        let context = try makeOffscreenContext()
        defer { CGLDestroyContext(context) }
        let player = MPVPlayer(backendPolicy: policy)
        defer { player.shutdown() }
        try XCTSkipUnless(player.phase == .idle, "mpv init 未成功(\(player.phase)),本条不适用")
        return try body(player, context)
    }

    func testGPUNextPolicyBuildsGPUNextBackend() throws {
        try withPlayer(.gpuNext) { player, context in
            player.attachGLContext(context)

            XCTAssertNotEqual(player.phase, .failed,
                              "attachGLContext 失败:\(player.initializationFailure ?? "-")")
            XCTAssertEqual(player.statisticsSnapshot().renderBackend, "gpu-next")
            XCTAssertTrue(player.statisticsSnapshot().glAttached)
        }
    }

    /// legacy 下 DV 会发紫发绿,这是用户自选的退路。
    func testLegacyPolicyBuildsLegacyGPUBackend() throws {
        try withPlayer(.legacy) { player, context in
            player.attachGLContext(context)

            XCTAssertNotEqual(player.phase, .failed,
                              "attachGLContext 失败:\(player.initializationFailure ?? "-")")
            XCTAssertEqual(player.statisticsSnapshot().renderBackend, "gpu")
        }
    }

    // MARK: - 自动(按片源)

    /// 片源还没加载时先建省电的 legacy。
    func testAutomaticPolicyStartsWithLegacyBackend() throws {
        try withPlayer(.automatic) { player, context in
            player.attachGLContext(context)
            XCTAssertEqual(player.statisticsSnapshot().renderBackend, "gpu")
        }
    }

    /// `on_preloaded` 里在 VO 建起之前换成 gpu-next。判据是 mpv 日志:VO(`VO: [libmpv] …`)之前
    /// 最后一次 `Using … backend.` 就是 VO 实际用的。fixture 是合成的(`Tools/dv-fixture/`):只有 `dvcC`,没有 RPU。
    func testAutomaticPolicySwitchesToGPUNextForDolbyVisionSource() throws {
        let run = try playFixture("dv_profile8_synthetic.mp4")
        XCTAssertEqual(run.backend, "gpu-next")
        XCTAssertEqual(run.backendLogsBeforeVO.last, "gpu-next",
                       "VO 应按 gpu-next 建起;最近日志:\n\(run.lines.suffix(40).joined(separator: "\n"))")
    }

    /// 同一段码流去掉 DV 配置记录:保持 legacy,渲染上下文只建过一次。
    func testAutomaticPolicyKeepsLegacyForNonDolbyVisionSource() throws {
        let run = try playFixture("sdr_hevc_synthetic.mp4")
        XCTAssertEqual(run.backend, "gpu")
        XCTAssertEqual(run.backendLogsBeforeVO, ["gpu"],
                       "不该换后端;最近日志:\n\(run.lines.suffix(40).joined(separator: "\n"))")
    }

    private struct FixtureRun {
        let backend: String?
        let lines: [String]
        /// VO 建起之前每次建渲染上下文时报的后端(`gpu-next` / `gpu`),按时间顺序
        let backendLogsBeforeVO: [String]
    }

    private func playFixture(_ name: String) throws -> FixtureRun {
        let url = try XCTUnwrap(fixtureURL(name), "找不到 fixture \(name)")
        return try withPlayer(.automatic) { player, context in
            player.attachGLContext(context)
            try player.load(url: url, headers: [:])

            // 等 player/video.c 的 `VO: [libmpv] …`;本地小文件通常 100ms 内出现
            let deadline = Date().addingTimeInterval(5)
            var lines: [String] = []
            var voIndex: Int?
            while Date() < deadline {
                lines = player.recentLogLines()
                voIndex = lines.firstIndex { $0.contains("VO: [libmpv]") }
                if voIndex != nil { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertNotEqual(player.phase, .failed, player.initializationFailure ?? "-")
            let vo = try XCTUnwrap(voIndex, "5s 内 VO 没建起来;最近日志:\n\(lines.suffix(40).joined(separator: "\n"))")
            let backends = lines[..<vo].compactMap { line -> String? in
                if line.contains("Using gpu-next backend.") { return "gpu-next" }
                if line.contains("Using default gpu backend.") { return "gpu" }
                return nil
            }
            return FixtureRun(
                backend: player.statisticsSnapshot().renderBackend, lines: lines, backendLogsBeforeVO: backends)
        }
    }

    /// 测试 bundle 里资源可能被展平,也可能保留子目录。
    private func fixtureURL(_ name: String) -> URL? {
        let bundle = Bundle(for: Self.self)
        if let url = bundle.url(forResource: name, withExtension: nil) { return url }
        let root = URL(fileURLWithPath: bundle.resourcePath ?? bundle.bundlePath)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }
}

final class MPVRenderBackendPolicyTests: XCTestCase {

    private func video(dv: Int? = nil, albumArt: Bool = false, id: Int = 1) -> MPVTrack {
        MPVTrack(id: id, type: .video, selected: false, title: nil, lang: nil, codec: "hevc",
                 isExternal: false, isForced: false, isAlbumArt: albumArt, dolbyVisionProfile: dv)
    }

    func testAutomaticUsesGPUNextOnlyForDolbyVision() {
        XCTAssertEqual(MPVRenderBackendPolicy.automatic.backend(for: [video(dv: 5)]), .gpuNext)
        XCTAssertEqual(MPVRenderBackendPolicy.automatic.backend(for: [video(dv: 8)]), .gpuNext)
        XCTAssertEqual(MPVRenderBackendPolicy.automatic.backend(for: [video()]), .legacy)
        XCTAssertEqual(MPVRenderBackendPolicy.automatic.backend(for: []), .legacy, "纯音频 / 没轨道")
    }

    /// 封面图不算画面,标了 DV 也不为它切后端。
    func testAutomaticIgnoresAlbumArt() {
        XCTAssertEqual(MPVRenderBackendPolicy.automatic.backend(for: [video(dv: 5, albumArt: true)]), .legacy)
        XCTAssertEqual(
            MPVRenderBackendPolicy.automatic.backend(for: [video(albumArt: true), video(dv: 5, id: 2)]),
            .gpuNext)
    }

    func testFixedPoliciesIgnoreTracks() {
        XCTAssertEqual(MPVRenderBackendPolicy.gpuNext.backend(for: [video()]), .gpuNext)
        XCTAssertEqual(MPVRenderBackendPolicy.legacy.backend(for: [video(dv: 5)]), .legacy)
    }

    func testInitialBackendIsLegacyUnlessForcedToGPUNext() {
        XCTAssertEqual(MPVRenderBackendPolicy.automatic.initialBackend, .legacy)
        XCTAssertEqual(MPVRenderBackendPolicy.legacy.initialBackend, .legacy)
        XCTAssertEqual(MPVRenderBackendPolicy.gpuNext.initialBackend, .gpuNext)
    }
}
