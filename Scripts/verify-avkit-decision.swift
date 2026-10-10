// verify-avkit-decision.swift
//
// P2 的 FFI 自检:一个**独立可执行文件**,不经 XCTest 宿主。
//
// 为什么需要它(而不是只靠 `xcodebuild test`):
//   本机 `sandbox_apply` 对所有 deny-default 沙箱都返回 `Operation not permitted`。
//   带 `com.apple.security.app-sandbox` 的 App 在**进程启动阶段**就 SIGTRAP
//   (崩溃栈在 `libsystem_secinit.dylib::_libsecinit_appsandbox`),
//   于是测试宿主永远建立不了连接:`The test runner hung before establishing connection`。
//   ⛔ 这与本项目的代码无关,是环境问题(`docs/KNOWN_ISSUES.md` Q34)。
//
// 定位:与 `LumaPlayerTests/RustPlaybackDecisionTests.swift` **断言等价**,是那套
// XCTest 跑不起来时的替代证据。在测试宿主的机器上,XCTest 才是正路。
//
// 跑法见同目录 `verify-avkit-decision.sh`。

import Foundation

@main
@MainActor
enum AvkitDecisionSelfCheck {

    /// 期望的决策结果(逐维度)
    private struct Expected {
        let method: String
        let pathActions: [String]
        let subtitleAction: String?
    }

    private static var checks = 0
    private static var failures: [String] = []

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    private static func readFixture(_ name: String) -> String {
        let path = "LumaPlayerTests/Fixtures/Playback/\(name)"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            failures.append("读不到 fixture \(path)(请在仓库根运行本脚本)")
            return "{}"
        }
        return text
    }

    static func main() {
        // ---------------------------------------------------------- 1. DeviceProfile
        let profile = avkitDeviceProfileJson()
        expect(profile.contains("DirectPlayProfiles"), "DeviceProfile 缺 DirectPlayProfiles:\(profile)")
        expect(profile.contains("\"mp4\""), "DeviceProfile 的直放白名单里应有 mp4")
        expect(!profile.contains("mkv"), "DeviceProfile 不该声明 MKV")
        expect(!profile.contains("hdmv_pgs_subtitle"), "DeviceProfile 不该声明位图字幕")
        print("· DeviceProfile 由 Rust 派生,白名单里无 MKV、无位图字幕")

        // ---------------------------------------------------------- 2. 四类真实片源
        let cases: [(String, Expected)] = [
            ("playback_mp4_h264_aac.json",
             Expected(method: "DirectStream", pathActions: [], subtitleAction: "转换字幕为文本")),
            ("playback_mkv_h264_aac.json",
             Expected(method: "Transcode", pathActions: ["重封装容器"], subtitleAction: "转换字幕为文本")),
            ("playback_mkv_h264_dts.json",
             Expected(method: "Transcode", pathActions: ["重封装容器", "转码音频"], subtitleAction: nil)),
            ("playback_mkv_hevc_pgs.json",
             Expected(method: "Transcode", pathActions: ["重封装容器"], subtitleAction: "烧录字幕")),
        ]

        for (file, want) in cases {
            do {
                let decision = try decidePlayback(playbackInfoJson: readFixture(file))
                expect(decision.method == want.method,
                       "\(file): 播放方式应为 \(want.method),实际 \(decision.method)")
                expect(decision.audit.pathActions == want.pathActions,
                       "\(file): 服务端动作应为 \(want.pathActions),实际 \(decision.audit.pathActions)")
                expect(decision.audit.subtitleAction == want.subtitleAction,
                       "\(file): 字幕处理应为 \(String(describing: want.subtitleAction)),"
                       + "实际 \(String(describing: decision.audit.subtitleAction))")
                expect(decision.audit.unverifiableDimensions.isEmpty,
                       "\(file): MediaStreams 齐全,不该有判不了的维度 \(decision.audit.unverifiableDimensions)")
                expect(!decision.capabilityRevision.isEmpty, "\(file): 应带上能力表版本号")
                print("· \(file)\n    → \(decision.method)(\(decision.methodDisplayName))"
                      + " / 服务端:\(decision.audit.pathActions)"
                      + " / 字幕:\(decision.audit.subtitleAction ?? "无")")
            } catch {
                failures.append("\(file): 决策抛错 \(error)")
            }
        }

        // ---------------------------------------------------------- 3. 静默失败守卫
        do {
            let decision = try decidePlayback(
                playbackInfoJson: readFixture("playback_mkv_direct_stream_silent_failure.json"))
            failures.append("静默失败样本应被拒绝,实际给出 \(decision.method)(这就会黑屏)")
        } catch let failure as PlaybackFailureFfi {
            if case let .UnplayableDirectStream(pathActions, notes, message) = failure {
                expect(pathActions == ["重封装容器"],
                       "守卫的 pathActions 应为 [重封装容器],实际 \(pathActions)")
                expect(!notes.isEmpty, "守卫必须带上可读理由")
                expect(message.contains("转码地址"), "守卫文案应点明缺的是转码地址,实际:\(message)")
                print("· 静默失败样本 → 被拒绝:\(message)")
            } else {
                failures.append("静默失败样本的错误类型不对:\(failure)")
            }
        } catch {
            failures.append("静默失败样本抛了非预期错误:\(error)")
        }

        // ---------------------------------------------------------- 4. 能力表版本
        let info = coreInfo()
        expect(info.capabilityRevision.contains("avkit-capability"),
               "coreInfo 应带能力表版本,实际 \(info.capabilityRevision)")
        expect(info.apiContract.contains("API_CONTRACT.md"), "apiContract 实际:\(info.apiContract)")
        print("· coreInfo:\(info.version) / \(info.capabilityRevision)")

        // ---------------------------------------------------------- 结论
        print("")
        if failures.isEmpty {
            print("✅ 通过:\(checks) 项断言全绿(真跑过 FFI 边界)")
            exit(0)
        }
        for f in failures { print("❌ \(f)") }
        print("共 \(failures.count)/\(checks) 项失败")
        exit(1)
    }
}
