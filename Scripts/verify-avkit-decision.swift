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
        expect(!profile.contains("mkv"), "DeviceProfile 不该声明 MKV")
        expect(!profile.contains("hdmv_pgs_subtitle"), "DeviceProfile 不该声明位图字幕")
        print("· DeviceProfile 由 Rust 派生,白名单里无 MKV、无位图字幕")

        // ⭐ P3 起声明是**多条** DirectPlayProfile(容器 × 视频编码 有例外组合),
        //    所以不能再拿整串 JSON 去 contains("\"mp4\"") —— Container 成了
        //    "mp4,m4v,mov" 这种逗号串。按 token 判,顺便把例外组合也守住。
        do {
            let root = try JSONSerialization.jsonObject(with: Data(profile.utf8)) as? [String: Any]
            let profiles = (root?["DirectPlayProfiles"] as? [[String: Any]]) ?? []
            expect(!profiles.isEmpty, "DeviceProfile 应能解析出 DirectPlayProfiles")

            let allContainers = Set(
                profiles.flatMap {
                    ($0["Container"] as? String)?.split(separator: ",").map(String.init) ?? []
                })
            expect(allContainers.contains("mp4"), "直放白名单里必须有 mp4,实际:\(allContainers)")
            expect(!allContainers.contains("mkv") && !allContainers.contains("webm"),
                   "直放白名单里不能有 mkv/webm,实际:\(allContainers)")

            var tsFamilyWithHEVC: [String] = []
            for one in profiles {
                let containers = Set(
                    (one["Container"] as? String)?.split(separator: ",").map(String.init) ?? [])
                let videoCodecs = Set(
                    (one["VideoCodec"] as? String)?.split(separator: ",").map(String.init) ?? [])
                if videoCodecs.contains("hevc"),
                    !containers.isDisjoint(with: ["ts", "m2ts", "mts", "mpegts"])
                {
                    tsFamilyWithHEVC.append("\(containers) × \(videoCodecs)")
                }
            }
            expect(tsFamilyWithHEVC.isEmpty,
                   "HEVC 不许与 TS 家族出现在同一条 DirectPlayProfile 里"
                       + "(实测那样会只有声音没有画面),实际:\(tsFamilyWithHEVC)")
            expect(profiles.count > 1,
                   "例外组合要求声明拆成多条 DirectPlayProfile,实际只有 \(profiles.count) 条")
            print("   → \(profiles.count) 条 DirectPlayProfile:"
                  + profiles.map {
                      "\n      容器[\($0["Container"] as? String ?? "?")]"
                          + " 视频[\($0["VideoCodec"] as? String ?? "?")]"
                  }.joined())
        } catch {
            failures.append("DeviceProfile 结构检查失败:\(error)")
        }

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

        // ---------------------------------------------------------- 5. P3 实测带出来的例外组合
        //
        // ⚠️ 这一组用的是**合成**的 PlaybackInfo(不是 `LumaPlayerTests/Fixtures/` 下的
        //    真实响应)—— 开发实例的媒体库里没有 .ts 片源。它只覆盖
        //    「容器=mpegts + 视频=hevc」这个组合的判定,不代替真实 fixture。
        //    真实 TS+HEVC 片源的 fixture 待补(文档第 9 节 R10)。
        //
        //    顺带验证 P2 那条静默失败守卫在新规则下也成立:例外组合被判成
        //    「需要服务端介入」,而响应里没有转码地址时 → 必须抛错而不是放行。
        print("\n· P3 实测的例外组合(合成样本)")

        struct SyntheticCase {
            let label: String
            let json: String
            /// 期望的服务端动作;nil 表示「应当被静默失败守卫拦下」
            let wantActions: [String]?
        }

        let synthetic: [SyntheticCase] = [
            SyntheticCase(
                label: "mpegts + h264(实测能放)有直连地址 → 接受",
                json: """
                    {"PlaySessionId":"probe-ts1","MediaSources":[{"Id":"ts1","Container":"mpegts",
                      "MediaStreams":[
                        {"Index":0,"Type":"Video","Codec":"h264"},
                        {"Index":1,"Type":"Audio","Codec":"ac3"}],
                      "SupportsDirectStream":true,
                      "DirectStreamUrl":"/videos/1/stream.mpegts?api_key=FAKE_TOKEN_0123456789"}]}
                    """,
                wantActions: []
            ),
            SyntheticCase(
                label: "mpegts + hevc 有直连地址却没转码地址 → 抛守卫",
                json: """
                    {"PlaySessionId":"probe-ts2","MediaSources":[{"Id":"ts2","Container":"mpegts",
                      "MediaStreams":[
                        {"Index":0,"Type":"Video","Codec":"hevc"},
                        {"Index":1,"Type":"Audio","Codec":"aac"}],
                      "SupportsDirectStream":true,
                      "DirectStreamUrl":"/videos/2/stream.mpegts?api_key=FAKE_TOKEN_0123456789"}]}
                    """,
                wantActions: nil
            ),
            SyntheticCase(
                label: "mpegts + hevc 服务端明确重封装 → 接受重封装",
                json: """
                    {"PlaySessionId":"probe-ts3","MediaSources":[{"Id":"ts3","Container":"mpegts",
                      "MediaStreams":[
                        {"Index":0,"Type":"Video","Codec":"hevc"},
                        {"Index":1,"Type":"Audio","Codec":"aac"}],
                      "SupportsDirectStream":false,
                      "TranscodingUrl":"/videos/3/stream.mp4?api_key=FAKE_TOKEN_0123456789",
                      "TranscodeReasons":"ContainerNotSupported"}]}
                    """,
                wantActions: ["重封装容器"]
            ),
            SyntheticCase(
                label: "mp3 音轨(实测会被静默丢弃)→ 要求转码音频",
                json: """
                    {"PlaySessionId":"probe-m4","MediaSources":[{"Id":"m4","Container":"mp4",
                      "MediaStreams":[
                        {"Index":0,"Type":"Video","Codec":"h264"},
                        {"Index":1,"Type":"Audio","Codec":"mp3"}],
                      "SupportsDirectStream":false,
                      "TranscodingUrl":"/videos/4/stream.mp4?api_key=FAKE_TOKEN_0123456789",
                      "TranscodeReasons":"AudioCodecNotSupported"}]}
                    """,
                wantActions: ["转码音频"]
            ),
        ]

        for testCase in synthetic {
            do {
                let decision = try decidePlayback(playbackInfoJson: testCase.json)
                guard let want = testCase.wantActions else {
                    failures.append("\(testCase.label):本该被静默失败守卫拦下,"
                        + "实际给出 \(decision.method)/\(decision.audit.pathActions)")
                    continue
                }
                expect(decision.audit.pathActions == want,
                       "\(testCase.label):服务端动作应为 \(want),实际 \(decision.audit.pathActions)")
                print("    · \(testCase.label) → \(decision.method) / \(decision.audit.pathActions)")
            } catch let failure as PlaybackFailureFfi {
                guard testCase.wantActions == nil else {
                    failures.append("\(testCase.label):不该抛错,却抛了 \(failure)")
                    continue
                }
                if case let .UnplayableDirectStream(pathActions, _, message) = failure {
                    expect(pathActions == ["重封装容器"],
                           "\(testCase.label):守卫应报出「需要重封装容器」,实际 \(pathActions)")
                    print("    · \(testCase.label) → 被拦下:\(message)")
                } else {
                    failures.append("\(testCase.label):错误类型不对:\(failure)")
                }
            } catch {
                failures.append("\(testCase.label):抛了非预期错误:\(error)")
            }
        }

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
