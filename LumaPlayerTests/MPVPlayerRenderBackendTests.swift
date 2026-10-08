import XCTest
import OpenGL
import OpenGL.GL3
@testable import LumaPlayer

/// `MPVPlayer` 的渲染后端选择:Dolby Vision / HDR 要靠 `gpu-next`(libplacebo),
/// 关掉偏好才走 legacy `gpu`。
///
/// ⚠️ **覆盖边界(照实说)**:
/// - 这里只验「离屏 GL 上下文下能把渲染上下文建起来,并记录了请求的后端名」。
/// - ⛔ **验不了画面颜色对不对** —— 那需要真实 DV 片源 + 目检,见
///   `docs/DECISIONS/gpu-next-render-backend.md` 的验证一节(本机用
///   harness 跑过 legacy=gpu 发紫绿 / gpu-next 正常,但那是 harness,不是这个测试)。
/// - ⛔ **也验不了「mpv 内部真的用了 gpu-next」**:实测后端名不被识别时 mpv 会
///   静默退回默认 gpu 渲染器且 `mpv_render_context_create` 仍返回成功。要确证
///   只能看 mpv 日志的 `Using gpu-next backend.` 行,单测里拿不到。
final class MPVPlayerRenderBackendTests: XCTestCase {

    /// 离屏 GL3 core context(mpv render API 要求 GL 2.1+ / 3.2 core)。
    /// 建不出来就 skip —— 无 GPU 的 CI 上不该判失败。
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

    /// 默认(gpu-next):建得起来,且统计里记的是 gpu-next。
    func testDefaultPrefersGPUNextBackend() throws {
        let context = try makeOffscreenContext()
        defer { CGLDestroyContext(context) }
        let player = MPVPlayer(preferGPUNextBackend: true)
        defer { player.shutdown() }
        try XCTSkipUnless(player.phase == .idle, "mpv init 未成功(\(player.phase)),本条不适用")

        player.attachGLContext(context)

        XCTAssertNotEqual(player.phase, .failed,
                          "attachGLContext 失败:\(player.initializationFailure ?? "-")")
        XCTAssertEqual(player.statisticsSnapshot().renderBackend, "gpu-next")
        XCTAssertTrue(player.statisticsSnapshot().glAttached)
    }

    /// 关掉偏好:仍建得起来,但走 legacy gpu(DV 会发紫发绿,这是用户自选的退路)。
    func testPreferenceOffFallsBackToLegacyGPUBackend() throws {
        let context = try makeOffscreenContext()
        defer { CGLDestroyContext(context) }
        let player = MPVPlayer(preferGPUNextBackend: false)
        defer { player.shutdown() }
        try XCTSkipUnless(player.phase == .idle, "mpv init 未成功(\(player.phase)),本条不适用")

        player.attachGLContext(context)

        XCTAssertNotEqual(player.phase, .failed,
                          "attachGLContext 失败:\(player.initializationFailure ?? "-")")
        XCTAssertEqual(player.statisticsSnapshot().renderBackend, "gpu")
    }
}
