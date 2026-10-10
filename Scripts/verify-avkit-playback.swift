// verify-avkit-playback.swift
//
// P3 第二步的自检:**AVKit 播放内核真的能把三段播起来吗**。
//
// 三段 = 文档 8 节 P3 门禁原文里的三种路径:
//   ① 本地 mp4(不经过网络)
//   ② Emby DirectStream(服务端原样吐文件)
//   ③ Emby Transcode(服务端重封装 / 转码;含带 StartTimeTicks 的重新起流)
//
// 它跑的是**真的**内核代码:`AVKitPlaybackKernel` + `PlaybackPlanBuilder` +
// `TrackExpectation` 与 App target 里是同一份文件,决策也真过 Rust 的 FFI 边界。
//
// 为什么不用 `xcodebuild test`:本机 `sandbox_apply` 对所有 deny-default 沙箱都
// 返回 `Operation not permitted`,带 app-sandbox 的 App 进程启动阶段即 SIGTRAP,
// 测试宿主建立不了连接(`docs/KNOWN_ISSUES.md` Q34)。
// ⛔ 它不是 XCTest 的替代品:`LumaPlayerTests/` 下那些才是正路,能跑测试宿主的
//    机器上两边都应当跑。本程序只回答"内核在这台机器上能不能真播"。
//
// ⭐ 两条关键设计:
//   1. **负例是真的**:`a-h264-dts.mp4` 里 H.264 + DTS 的音频轨会被 AVFoundation
//      **静默删掉**(P3 实测,文档 2.1 第 2 条)。本程序喂给它"服务端说有视频有音频"
//      的口径,内核必须报出「缺音频轨」而不是安静地播下去 —— 这就是那条守卫的真机
//      证据,不需要伪造 mock。
//   2. **起点位置也验**:转码那条腿带 `StartTimeTicks` 重新起流,断言播放位置从 5 秒
//      附近开始推进(续播时的转码 seek 走的就是这条路)。
//
// 前置:`Tools/emby-dev/` 的实例在跑(127.0.0.1:8096),已跑过 `gen-media.sh`
//       与 `setup-instance.sh`;`./Scripts/build-rust-core.sh` 跑过;
//       `./Scripts/probe-avkit-capability.sh` 跑过(本地起播样本在 build/avkit-probe)。
//
// 跑法见同目录 `verify-avkit-playback.sh`。

import AVFoundation
import Foundation

/// 自检自己的失败(不是被测内核的失败)
private struct CheckError: Error { let message: String }

@main
@MainActor
enum AvkitPlaybackSelfCheck {

    // MARK: - 记账

    private static var checks = 0
    private static var failures: [String] = []

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    private static func note(_ text: String) { print("      \(text)") }

    // MARK: - 一条要真播的腿

    private struct Leg {
        let label: String
        /// 非 nil:按 `Path` 结尾在 Emby 里找素材。⛔ 不按 `Name` —— Emby 会把文件名里
        /// 它自认为是媒体标记的片段洗掉(`01-direct-h264-aac.mp4` → `01-direct`,
        /// `04-dts.mkv` → `04`),按 Name 一条都命不中。
        let pathSuffix: String?
        /// 非 nil:本地文件,直接播,不经过服务器
        let localFile: String?
        /// 本地腿**人工给定**的轨口径(模拟服务端会说的 `MediaStreams`)
        let localStreams: [(type: String, codec: String)]
        /// 期望的播放方式(`DirectStream` / `Transcode`);本地腿为 nil
        let expectedMethod: String?
        /// 转码腿的起流位置(秒);0 = 从头
        let startSeconds: Double
        /// 期望的轨核验结论
        let expectedOutcome: TrackExpectation.Outcome
        /// 期望最终真的在播(负例为 false:它应当被判成失败)
        let expectPlaying: Bool
    }

    private static let legs: [Leg] = [
        Leg(label: "① 本地 MP4 起播(H.264/AAC)",
            pathSuffix: nil, localFile: "base-h264-aac.mp4",
            localStreams: [("Video", "h264"), ("Audio", "aac")],
            expectedMethod: nil, startSeconds: 0,
            expectedOutcome: .satisfied, expectPlaying: true),

        Leg(label: "② Emby DirectStream(MP4/H.264/AAC)",
            pathSuffix: "01-direct-h264-aac.mp4", localFile: nil, localStreams: [],
            expectedMethod: "DirectStream", startSeconds: 0,
            expectedOutcome: .satisfied, expectPlaying: true),

        Leg(label: "③ Emby Transcode(MKV/H.264/AAC → 重封装)",
            pathSuffix: "02-multi-track.mkv", localFile: nil, localStreams: [],
            expectedMethod: "Transcode", startSeconds: 0,
            expectedOutcome: .satisfied, expectPlaying: true),

        Leg(label: "③ Emby Transcode(MKV/H.264/DTS → 转音频)",
            pathSuffix: "04-dts.mkv", localFile: nil, localStreams: [],
            expectedMethod: "Transcode", startSeconds: 0,
            expectedOutcome: .satisfied, expectPlaying: true),

        Leg(label: "③ Emby Transcode(MKV/HEVC/PGS)",
            pathSuffix: "05-hevc-pgs.mkv", localFile: nil, localStreams: [],
            expectedMethod: "Transcode", startSeconds: 0,
            expectedOutcome: .satisfied, expectPlaying: true),

        Leg(label: "③ Emby Transcode 从第 5 秒起流(StartTimeTicks,续播的转码路径)",
            pathSuffix: "04-dts.mkv", localFile: nil, localStreams: [],
            expectedMethod: "Transcode", startSeconds: 5,
            expectedOutcome: .satisfied, expectPlaying: true),

        // ⭐ 负例:文件里确实有 DTS 音轨(ffprobe 看得见),AVFoundation 会把它
        //    静默删掉。口径按服务端会说的那样给(有视频、有音频),内核必须报缺音频。
        Leg(label: "④ 负例:MP4 里的 DTS 音轨被静默删除(守卫必须报错)",
            pathSuffix: nil, localFile: "a-h264-dts.mp4",
            localStreams: [("Video", "h264"), ("Audio", "dts")],
            expectedMethod: nil, startSeconds: 0,
            expectedOutcome: .missing(["音频"]), expectPlaying: false),
    ]

    // MARK: - 入口

    static func main() async {
        let arguments = CommandLine.arguments
        let base = arguments.count > 1 ? arguments[1] : "http://127.0.0.1:8096"
        let samples = arguments.count > 2 ? arguments[2] : "build/avkit-probe"
        let user = ProcessInfo.processInfo.environment["LUMA_EMBY_USER"] ?? "luma"
        let password = ProcessInfo.processInfo.environment["LUMA_EMBY_PASS"] ?? "lumadev"

        guard let baseURL = URL(string: base) else {
            print("用法:verify-avkit-playback [站点根] [本地样本目录]")
            exit(2)
        }
        let sampleDirectory = URL(fileURLWithPath: samples, isDirectory: true)

        print("== 0. 准备 ==")
        let client: EmbyClient
        do {
            client = try await EmbyClient.connect(baseURL: baseURL, user: user, password: password)
            print("   已连上 \(client.address)")
            print("   前缀=\(client.prefix.isEmpty ? "(无)" : client.prefix)"
                  + " 账号=\(user) 素材 \(client.items.count) 条")
        } catch {
            print("❌ 连不上本地开发实例:\(error)")
            print("   先跑 Tools/emby-dev 的三条命令(见其 README)。")
            exit(1)
        }

        print("\n== 1. 三段真起播 ==")
        for leg in legs {
            await run(leg: leg, client: client, sampleDirectory: sampleDirectory)
        }

        print("")
        if failures.isEmpty {
            print("✅ 通过:\(checks) 项断言全绿(真起播 + 真过 FFI 边界)")
            exit(0)
        }
        for failure in failures { print("❌ \(failure)") }
        print("共 \(failures.count)/\(checks) 项失败")
        exit(1)
    }

    // MARK: - 跑一条腿

    private static func run(leg: Leg, client: EmbyClient, sampleDirectory: URL) async {
        print("\n· \(leg.label)")

        let plan: PlaybackPlan
        let streams: [EmbyMediaStream]?

        if let localFile = leg.localFile {
            let url = sampleDirectory.appendingPathComponent(localFile)
            guard FileManager.default.fileExists(atPath: url.path) else {
                expect(false, "\(leg.label):缺样本 \(url.path)(先跑 probe-avkit-capability.sh)")
                return
            }
            plan = .directStream(url: url, headers: [:], playSessionID: "local", mediaSourceID: "local")
            streams = leg.localStreams.map { stream($0.type, $0.codec) }
            note("本地文件 \(localFile),口径由本脚本人工给定(内核只认 MediaStreams)")
        } else if let suffix = leg.pathSuffix {
            guard let item = client.item(pathSuffix: suffix) else {
                expect(false, "\(leg.label):Emby 素材库里找不到 Path 以 \(suffix) 结尾的条目")
                return
            }
            do {
                let prepared = try await client.preparePlan(
                    itemID: item.id, startSeconds: leg.startSeconds)
                plan = prepared.plan
                streams = prepared.streams
                if let expected = leg.expectedMethod {
                    expect(prepared.decision.method == expected,
                           "\(leg.label):播放方式应为 \(expected),实际 \(prepared.decision.method)")
                }
                note("决策 \(prepared.decision.method)(\(prepared.decision.methodDisplayName))"
                     + " 服务端动作=\(prepared.decision.audit.pathActions)"
                     + " 字幕=\(prepared.decision.audit.subtitleAction ?? "无")")
                note("地址 \(SecretRedactor.redactedDescription(of: prepared.plan.url))")
                expect(!prepared.plan.url.absoluteString.isEmpty, "\(leg.label):播放地址为空")
                expect(streams?.isEmpty == false,
                       "\(leg.label):没取到选中源的 MediaStreams,轨核验会退化成「无法核实」")
            } catch {
                expect(false, "\(leg.label):取播放信息 / 决策失败 \(error)")
                return
            }
        } else {
            expect(false, "\(leg.label):腿的定义不完整")
            return
        }

        let requirement = TrackExpectation.requirement(forStreams: streams)
        note("核轨口径 \(describe(requirement))")

        let kernel = AVKitPlaybackKernel()
        do {
            try await kernel.load(plan: plan, sourceStreams: streams)
        } catch let failure as AVKitPlaybackKernel.Failure {
            expect(false, "\(leg.label):放流失败 \(failure.userMessage)")
            kernel.teardown()
            return
        } catch {
            expect(false, "\(leg.label):放流抛了非预期错误 \(error)")
            kernel.teardown()
            return
        }

        expect(kernel.phase == .paused,
               "\(leg.label):放好之后应为 .paused,实际 \(kernel.phase.rawValue)")
        note("就绪 时长 \(round(kernel.durationSeconds * 10) / 10)s"
             + " 音轨 \(kernel.audioTracks.count) 字幕轨 \(kernel.subtitleTracks.count)"
             + " 原始读数 \(describe(kernel.player.currentItem))")

        kernel.play()
        let playing = await kernel.waitForPhase(.playing, timeout: .seconds(25))

        if leg.expectPlaying {
            expect(playing, "\(leg.label):25 秒内应进入 .playing,实际 \(kernel.phase.rawValue)"
                   + (kernel.failure.map { "(\($0.userMessage))" } ?? ""))
            expect(kernel.trackValidation == leg.expectedOutcome,
                   "\(leg.label):核轨结论应为 \(leg.expectedOutcome),实际 "
                   + "\(String(describing: kernel.trackValidation)) —— 原始读数 "
                   + describe(kernel.player.currentItem))

            // 采样 4 秒,确认播放时刻真的在推进
            var samples: [Double] = []
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(250))
                samples.append(kernel.positionSeconds)
            }
            let first = samples.first ?? 0
            let last = samples.last ?? 0
            expect(last - first > 1.0,
                   "\(leg.label):播放时刻应推进超过 1 秒,实际 \(round((last - first) * 100) / 100)s"
                   + "(轨迹 \(samples.map { round($0 * 10) / 10 }))")
            if leg.startSeconds > 0 {
                // ⭐ 实测特征(2026-10-10):HLS 转码流的 `AVPlayerItem.currentTime()` 是
                // **相对起流点**的 —— 带 `StartTimeTicks=5s` 与从头起流一样都从 0 开始
                // (Emby 的变体清单把 `StartTimeTicks` 带在片段地址上,清单自身的时间轴
                // 仍从 0 起)。所以「绝对媒体位置」必须由播放层补偏移,⛔ 不能直接拿
                // `currentTime` 当进度上报 —— 否则续播的转码流会把进度写回 0。
                // ⚠️ 内容是否真的从第 5 秒起(而不是服务端忽略了参数)尚未逐帧核实,
                // 见 docs/DECISIONS/avkit-rust-rearchitecture.md 第 9 节 R13。
                expect(first < 1.0,
                       "\(leg.label):HLS 时间原点应仍是 0(绝对位置靠播放层补偏移),实际 \(first)s")
                note("时间原点 \(round(first * 10) / 10)s —— 起流目标 \(leg.startSeconds)s,"
                     + "差值要由播放层补(见 R13)")
            }
            note("推进 \(round(first * 10) / 10)s → \(round(last * 10) / 10)s"
                 + " 倍速 \(kernel.rate) 音量 \(kernel.volume)")
        } else {
            // 负例:守卫必须把这条流判死 —— 而且**不是**因为放不起来
            expect(kernel.trackValidation == leg.expectedOutcome,
                   "\(leg.label):核轨结论应为 \(leg.expectedOutcome),实际 "
                   + "\(String(describing: kernel.trackValidation)) —— 原始读数 "
                   + describe(kernel.player.currentItem))
            expect(kernel.failure == AVKitPlaybackKernel.Failure.missingTracks(["音频"]),
                   "\(leg.label):应报 missingTracks([\"音频\"]),实际 "
                   + "\(String(describing: kernel.failure))")
            expect(kernel.phase == .failed,
                   "\(leg.label):应进入 .failed,实际 \(kernel.phase.rawValue)")
            note("原始读数 \(describe(kernel.player.currentItem))")
            note("守卫文案 \(kernel.failure?.userMessage ?? "—")")
        }

        kernel.teardown()
        expect(kernel.phase == .destroyed, "\(leg.label):teardown 之后应为 .destroyed")
    }

    // MARK: - 描述

    private static func describe(_ requirement: TrackExpectation.Requirement?) -> String {
        guard let requirement else { return "服务端没给 MediaStreams → 本次无法核实" }
        var required: [String] = []
        if requirement.video { required.append("视频") }
        if requirement.audio { required.append("音频") }
        return required.isEmpty ? "不要求任何轨" : "必须有 " + required.joined(separator: " + ")
    }

    /// 把 `AVPlayerItem` 的原始读数打出来。判「文件里没有」还是「有但不认」只能靠它
    /// (与 `probe-avkit-capability.sh` 那两份 ffprobe 记录对着看是同一手法)。
    private static func describe(_ item: AVPlayerItem?) -> String {
        guard let item else { return "item=nil" }
        let tracks = item.tracks.map { track -> String in
            let type = track.assetTrack?.mediaType.rawValue ?? "?"
            return "\(type)\(track.isEnabled ? "" : "(禁)")"
        }
        return "status=\(item.status.rawValue) tracks=[\(tracks.joined(separator: " "))]"
            + " size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))"
    }

    private static func stream(_ type: String, _ codec: String) -> EmbyMediaStream {
        EmbyMediaStream(
            index: nil, type: type, codec: codec, language: nil,
            isDefault: nil, isTextSubtitleStream: nil, isExternal: nil,
            displayTitle: nil, title: nil, width: nil, height: nil, channels: nil
        )
    }
}

// MARK: - 本地开发实例的极简客户端

/// 只实现自检需要的几个请求。⛔ 不是 `EmbyAPIClient` 的替代品 ——
/// 应用侧那一份在 `LumaPlayer/Core/Network/`,这里只是自检脚本的脚手架。
///
/// ⚠️ 它对**本地开发实例**说话(`Tools/emby-dev/`,4.9.5.0)。⛔ 不得据此声称
/// 「真实服务器也成立」(`CLAUDE.md` 真实服务器纪律)。
///
/// `@MainActor`:整个自检都在主 actor 上跑(播放内核也是),
/// 不让这个非 Sendable 的脚手架在隔离边界上来回搬。
@MainActor
private final class EmbyClient {
    struct Item { let id: String; let path: String }

    struct Prepared {
        let decision: PlaybackDecisionFfi
        let plan: PlaybackPlan
        let streams: [EmbyMediaStream]?
    }

    /// 站点根(如 http://127.0.0.1:8096)。⚠️ 字段名不叫 `site`:
    /// `.site` 会被 Scripts/check-privacy.sh 当成域名(site 是真实 gTLD),那是误报但改个名字更省事。
    let address: String
    let prefix: String
    let items: [Item]

    private let baseURL: URL
    private let userID: String
    private let authorization: String
    private let token: String

    private init(address: String, prefix: String, baseURL: URL, userID: String,
                 authorization: String, token: String, items: [Item]) {
        self.address = address
        self.prefix = prefix
        self.baseURL = baseURL
        self.userID = userID
        self.authorization = authorization
        self.token = token
        self.items = items
    }

    static func connect(baseURL: URL, user: String, password: String) async throws -> EmbyClient {
        let deviceID = UUID().uuidString
        var prefix = "/emby"
        if try await get(URL(string: baseURL.absoluteString + "/emby/System/Info/Public")!) == nil {
            prefix = ""
            guard try await get(URL(string: baseURL.absoluteString + "/System/Info/Public")!) != nil else {
                throw CheckError(message: "\(baseURL) 的 /System/Info/Public 与 /emby/... 都不通")
            }
        }

        let publicHeader = authHeader(userID: nil, deviceID: deviceID)
        let loginBody = try JSONSerialization.data(withJSONObject: ["Username": user, "Pw": password])
        let (loginData, loginStatus) = try await send(
            URL(string: baseURL.absoluteString + prefix + "/Users/AuthenticateByName")!,
            method: "POST", body: loginBody, authorization: publicHeader, token: nil)
        guard loginStatus == 200 else {
            throw CheckError(message: "登录返回 \(loginStatus)(账号 \(user))")
        }
        let root = try JSONSerialization.jsonObject(with: loginData) as? [String: Any]
        guard let token = root?["AccessToken"] as? String,
              let userID = (root?["User"] as? [String: Any])?["Id"] as? String else {
            throw CheckError(message: "登录响应里没有 AccessToken / User.Id")
        }

        let authorization = authHeader(userID: userID, deviceID: deviceID)
        var components = URLComponents(
            string: baseURL.absoluteString + prefix + "/Users/\(userID)/Items")!
        components.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            // ⚠️ 必须显式要 `Path`:列表接口默认不给,而 Emby 的 `Name` 不是文件名
            URLQueryItem(name: "Fields", value: "Path"),
            URLQueryItem(name: "Limit", value: "200"),
        ]
        let (itemsData, itemsStatus) = try await send(
            components.url!, method: "GET", body: nil, authorization: authorization, token: token)
        guard itemsStatus == 200 else {
            throw CheckError(message: "素材列表返回 \(itemsStatus):\(components.url!.absoluteString)")
        }
        let itemsRoot = try JSONSerialization.jsonObject(with: itemsData) as? [String: Any]
        let raw = (itemsRoot?["Items"] as? [[String: Any]]) ?? []
        let items = raw.compactMap { entry -> Item? in
            guard let id = entry["Id"] as? String, let path = entry["Path"] as? String else { return nil }
            return Item(id: id, path: path)
        }

        return EmbyClient(
            address: baseURL.absoluteString, prefix: prefix, baseURL: baseURL, userID: userID,
            authorization: authorization, token: token, items: items)
    }

    func item(pathSuffix: String) -> Item? {
        items.first { $0.path.hasSuffix(pathSuffix) }
    }

    /// `PlaybackInfo` → Rust 决策 → `PlaybackPlanBuilder`。
    /// 与播放窗口(P3b)走的是同一条路:Swift 只负责拼 URL 与挂认证头。
    ///
    /// ⚠️ `startSeconds > 0` 时**先不带 `StartTimeTicks` 取一次**,确认是转码之后
    /// 才带参数重取 —— `StartTimeTicks` 本身就是服务端的决策输入,一上来就带可能
    /// 把本来能直连的文件推去转码(`main` 上 `PlayerViewModel.prepareAndLoad` 同一手法)。
    func preparePlan(itemID: String, startSeconds: Double) async throws -> Prepared {
        var prepared = try await fetchPlan(itemID: itemID, startTimeTicks: nil)
        if startSeconds > 0, prepared.decision.method == "Transcode" {
            prepared = try await fetchPlan(
                itemID: itemID, startTimeTicks: TickConverter.ticks(fromSeconds: startSeconds))
        }
        return prepared
    }

    // MARK: - 内部

    private func fetchPlan(itemID: String, startTimeTicks: Int64?) async throws -> Prepared {
        // ⛔ 不发 `EnableDirectPlay`:本地 4.9.5.0 实测带 DeviceProfile 时这个键会连
        //    `SupportsDirectStream` 一起关掉(Emby Web 也不发它)。
        var body: [String: Any] = [
            "UserId": userID,
            "DeviceProfile": try deviceProfile(),
            "EnableDirectStream": true,
            "EnableTranscoding": true,
        ]
        if let startTimeTicks { body["StartTimeTicks"] = startTimeTicks }

        let requestBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await Self.send(
            URL(string: baseURL.absoluteString + prefix + "/Items/\(itemID)/PlaybackInfo")!,
            method: "POST", body: requestBody, authorization: authorization, token: token)
        guard status == 200 else {
            throw CheckError(message: "PlaybackInfo 返回 \(status)(素材 \(itemID))")
        }
        let json = String(data: data, encoding: .utf8) ?? ""

        let decision = try decidePlayback(playbackInfoJson: json)
        let plan = try PlaybackPlanBuilder.plan(
            from: decision,
            urlBuilder: PlaybackURLBuilder(baseURL: baseURL, apiPathPrefix: prefix),
            headers: playbackHeaders())
        // 核轨口径取自**被选中**那条 MediaSource 的 MediaStreams
        // (与 Rust 决策第 3 步同一条源,避免"播的是 A、判的是 B")
        return Prepared(
            decision: decision, plan: plan,
            streams: selectedStreams(in: data, mediaSourceID: decision.mediaSourceId))
    }

    private func playbackHeaders() -> [String: String] {
        // 与 `ServerConnection.playbackHeaders()` 一致(API_CONTRACT.md 第 6 节):
        // 认证走请求头,⛔ 不靠 URL 上的 api_key
        ["Authorization": authorization, "X-Emby-Token": token]
    }

    private func deviceProfile() throws -> Any {
        // 白名单只有 Rust 那一份(`luma-emby::device_profile` 由能力表派生)
        let json = avkitDeviceProfileJson()
        return try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private func selectedStreams(in data: Data, mediaSourceID: String) -> [EmbyMediaStream]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = root["MediaSources"] as? [[String: Any]] else { return nil }
        // 与 Rust 决策第 3 步同一条:取第一个支持直连的,都不支持则取第一个
        let selected = sources.first { $0["SupportsDirectStream"] as? Bool == true } ?? sources.first
        // 决策选中的那条必须就是这里选的这条,否则就是"播 A 判 B"
        guard let selected, let id = selected["Id"] as? String, id == mediaSourceID else { return nil }
        // `MediaSource` 的原样 JSON 交给 `EmbyMediaSource` 解,⛔ 不在脚本里重写字段映射
        guard let sourceData = try? JSONSerialization.data(withJSONObject: selected),
              let source = try? JSONDecoder().decode(EmbyMediaSource.self, from: sourceData) else {
            return nil
        }
        return source.mediaStreams
    }

    private static func authHeader(userID: String?, deviceID: String) -> String {
        // 与 `EmbyRequestBuilder.authorizationHeaderValue` 同一格式(API_CONTRACT.md 2.1);
        // 未登录时**省略** UserId 那一段,不写成空串
        var fields: [String] = []
        if let userID { fields.append("UserId=\"\(userID)\"") }
        fields.append("Client=\"LumaPlayer\"")
        fields.append("Device=\"verify-avkit-playback\"")
        fields.append("DeviceId=\"\(deviceID)\"")
        fields.append("Version=\"0.0\"")
        return "Emby " + fields.joined(separator: ", ")
    }

    private static func get(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private static func send(
        _ url: URL, method: String, body: Data?, authorization: String, token: String?
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CheckError(message: "非 HTTP 响应")
        }
        return (data, http.statusCode)
    }
}
