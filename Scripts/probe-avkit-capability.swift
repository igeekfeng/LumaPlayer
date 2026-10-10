// probe-avkit-capability.swift
//
// P3 的第一件事:`docs/DECISIONS/avkit-rust-rearchitecture.md` 第 2 节那张
// 「AVFoundation 能力边界表」**全部是二手来源**(文档的 R7 / `capability.rs` 的
// `revision` 都写着「未在本机实测」)。本程序把它逐项在本机 AVFoundation 上
// 实测一遍,用来回填那张表。
//
// 为什么是一个独立可执行文件:
//   本机 `xcodebuild test` 不可用(测试宿主建立不了连接,见 `KNOWN_ISSUES.md` Q34),
//   与 P1/P2 那两次自检同一手法。⛔ 它不替代 XCTest;能跑测试宿主的机器上,
//   `LumaPlayerTests/` 下的 XCTest 才是正路。
//
// 喂给它的样本由同目录 `probe-avkit-capability.sh` 现造:把音轨 / 字幕轨**单独**
// 重封装进不同容器,才能把「容器不支持」与「编码不支持」两件事分开 ——
// 直接拿 MKV 去测,任何失败都只能得出「MKV 打不开」,分不出是哪一维的问题。
//
// ⭐ 关键设计:同目录下还有一份 `.ffprobe-tracks.txt`(由 .sh 用 ffprobe 生成),
//    记着**文件里实际有哪些轨**。AVFoundation 遇到不认识的编码不是报错,而是
//    把那条轨**悄悄丢掉** —— 只看 AVFoundation 的返回,分不清「文件里没有」
//    与「有但不认」。两边的轨数一比,才能把这件事说清。
//
// 跑法:见同目录 `probe-avkit-capability.sh`。

import AVFoundation
import CoreMedia
import Foundation

@main
@MainActor
enum AvkitCapabilityProbe {

    // MARK: - 结果记账

    private static var checks = 0
    private static var refuted: [String] = []

    private static func expect(_ condition: Bool, _ hypothesis: String, _ actual: String) {
        checks += 1
        if condition {
            print("  ✅ \(hypothesis)")
        } else {
            print("  ❌ \(hypothesis)\n     实测:\(actual)")
            refuted.append("\(hypothesis) —— 实测:\(actual)")
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let scalars = bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// 把 AVFoundation 的 mediaType 折成 ffprobe 的写法,方便两边对齐看
    nonisolated private static func shortType(_ raw: String) -> String {
        switch raw {
        case "vide": return "video"
        case "soun": return "audio"
        case "sbtl", "text", "clcp": return "subtitle"
        default: return raw
        }
    }

    // MARK: - ffprobe 侧:文件里实际有什么

    /// `[文件名: ["vide/hevc", "soun/aac", ...]]`
    private static func loadActualTracks(_ dir: URL) -> [String: [String]] {
        var table: [String: [String]] = [:]
        let path = dir.appendingPathComponent(".ffprobe-tracks.txt")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return table }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count == 3 else { continue }
            table[parts[0], default: []].append("\(parts[1])/\(parts[2])")
        }
        return table
    }

    // MARK: - AVFoundation 侧:它认下来什么

    private struct TrackInfo {
        var mediaType: String
        var fourCC: String
        var isPlayable: Bool
        var isDecodable: Bool
    }

    private struct ProbeResult {
        var opened = false
        var openError: String?
        var isPlayable = false
        var tracks: [TrackInfo] = []
        var legibleOptions: [String] = []
        var hasLegibleGroup = false

        var videoDecodable: Bool { tracks.contains { $0.mediaType == "vide" && $0.isDecodable } }
        var audioDecodable: Bool { tracks.contains { $0.mediaType == "soun" && $0.isDecodable } }
        var videoExposed: Bool { tracks.contains { $0.mediaType == "vide" } }
        var audioExposed: Bool { tracks.contains { $0.mediaType == "soun" } }
        var exposedCount: Int { tracks.count }

        /// AVFoundation 侧暴露出来的轨,写成 `vide/avc1 soun/aac` 的形式
        var exposedSummary: String {
            tracks
                .map { "\(shortType($0.mediaType))/\($0.fourCC)\($0.isDecodable ? "" : "⛔不可解")" }
                .joined(separator: " ")
        }

        var legibleSummary: String {
            hasLegibleGroup ? "legible[\(legibleOptions.joined(separator: ","))]" : "无 legible 组"
        }
    }

    private static func probe(_ dir: URL, _ name: String) async -> ProbeResult {
        var result = ProbeResult()
        let asset = AVURLAsset(url: dir.appendingPathComponent(name))
        do {
            result.isPlayable = try await asset.load(.isPlayable)
            let tracks = try await asset.load(.tracks)
            result.opened = true
            for track in tracks {
                let descriptions = try await track.load(.formatDescriptions)
                let subType = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                result.tracks.append(
                    TrackInfo(
                        mediaType: track.mediaType.rawValue,
                        fourCC: fourCC(subType),
                        isPlayable: try await track.load(.isPlayable),
                        isDecodable: try await track.load(.isDecodable)
                    )
                )
            }
            let characteristics = try await asset.load(
                .availableMediaCharacteristicsWithMediaSelectionOptions)
            result.hasLegibleGroup = characteristics.contains(.legible)
            if result.hasLegibleGroup,
                let group = try await asset.loadMediaSelectionGroup(for: .legible)
            {
                result.legibleOptions = group.options.map {
                    "\($0.displayName)[\($0.locale?.identifier ?? $0.extendedLanguageTag ?? "?")]"
                }
            }
        } catch {
            result.openError = "\(error)"
        }
        return result
    }

    /// 打印一条样本的完整证据:ffprobe 说文件里有什么 vs AVFoundation 认下来什么
    private static func report(_ name: String, _ r: ProbeResult, actual: [String: [String]]) {
        let inFile = (actual[name] ?? []).joined(separator: " ")
        if let e = r.openError {
            print("   \(name)\n      文件里:\(inFile)\n      ⛔ 打不开:\(e.prefix(80))")
        } else {
            print("   \(name)\n      文件里:\(inFile)\n"
                  + "      认下来:playable=\(r.isPlayable) 轨=\(r.exposedCount)"
                  + " [\(r.exposedSummary)] \(r.legibleSummary)")
        }
    }

    // MARK: - 主流程

    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("用法:probe-avkit-capability <样本目录>")
            exit(2)
        }
        let dir = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let actual = loadActualTracks(dir)

        // ============================================== 1. 容器维:系统自报的支持类型
        print("== 1. 系统自报的支持类型(容器维) ==")
        // ⚠️ macOS 27 起 `AVURLAsset.audiovisualTypes()` 被弃用,替代是
        //    `audiovisualContentTypes`。本项目只跑 macOS 27,所以直接用新的。
        let contentTypes = AVURLAsset.audiovisualContentTypes.map { $0.identifier }
        print("   audiovisualContentTypes 共 \(contentTypes.count) 项:")
        print("   " + contentTypes.joined(separator: " "))
        print("   (没有 matroska / webm 这一族)")
        expect(!contentTypes.contains { $0.contains("matroska") },
               "系统自报的容器列表里没有 Matroska(MKV 不被解复用器接受)",
               "列表里出现了 matroska:*")
        expect(!contentTypes.contains { $0.contains("webm") },
               "系统自报的容器列表里没有 WebM", "列表里出现了 webm:*")

        // ============================================== 2. 容器维:真实素材
        print("\n== 2. Emby 开发实例的 5 条真实素材(容器维) ==")
        let real: [(String, Bool)] = [
            ("01-direct-h264-aac.mp4", true),
            ("02-multi-track.mkv", false),
            ("03-transcode-hevc.mkv", false),
            ("04-dts.mkv", false),
            ("05-hevc-pgs.mkv", false),
        ]
        for (name, shouldOpen) in real {
            let r = await probe(dir, name)
            report(name, r, actual: actual)
            expect(r.opened == shouldOpen,
                   shouldOpen ? "\(name)能被 AVURLAsset 打开" : "\(name)打不开(容器不被接受)",
                   r.openError ?? "opened=\(r.opened) playable=\(r.isPlayable)")
        }

        // ============================================== 3. 视频维
        print("\n== 3. 视频维:HEVC Main10 换三种装法 + H.264 进 TS 做对照 ==")
        let videoCases = ["v-hevc-hvc1.mp4", "v-hevc-hev1.mp4", "v-hevc.ts", "v-h264.ts"]
        var probed: [String: ProbeResult] = [:]
        for name in videoCases {
            let r = await probe(dir, name)
            probed[name] = r
            report(name, r, actual: actual)
        }
        // H.264 进 TS:这是 Emby 转码 / HLS 最常见的输出形态,先确认容器本身能用
        if let h264TS = probed["v-h264.ts"] {
            expect(h264TS.videoDecodable && h264TS.audioDecodable,
                   "H.264+AAC 进 MPEG-TS:视频与音频轨都可解(TS 容器本身没问题)",
                   h264TS.exposedSummary)
        }
        // HEVC 进 MP4:四个字符的 tag 决定生死
        expect(probed["v-hevc-hvc1.mp4"]?.videoDecodable == true,
               "HEVC(Main10)进 MP4、tag=hvc1:视频轨可解",
               probed["v-hevc-hvc1.mp4"]?.exposedSummary ?? "—")
        // ⭐ 实测推翻的假设之一
        let hev1 = probed["v-hevc-hev1.mp4"]
        expect(hev1?.videoDecodable == true,
               "HEVC(Main10)进 MP4、tag=hev1:视频轨同样可解",
               "playable=\(hev1?.isPlayable ?? false) \(hev1?.exposedSummary ?? "—")")
        // ⭐ 实测推翻的假设之二 —— 这条最要紧
        let hevcTS = probed["v-hevc.ts"]
            expect(hevcTS?.videoDecodable == true,
                   "HEVC(Main10)进 MPEG-TS:视频轨可解",
                   "文件里有 \(actual["v-hevc.ts"]?.count ?? 0) 种轨型,"
                   + "AVFoundation 只认下 \(hevcTS?.exposedCount ?? 0) 条:[\(hevcTS?.exposedSummary ?? "—")]")

        // ============================================== 4. 音频维
        print("\n== 4. 音频维:同一条 H.264 视频配不同音轨 ==")
        for name in ["a-h264-ac3.mp4", "a-h264-eac3.mp4", "a-h264-ac3.ts", "a-h264-eac3.ts",
                     "a-h264-flac.mp4", "a-h264-alac.mp4", "a-h264-mp3.mp4", "a-h264-mp3.mp3",
                     "a-h264-dts.mp4", "a-h264-dts.ts", "a-h264-truehd.ts"] {
            let r = await probe(dir, name)
            probed[name] = r
            report(name, r, actual: actual)
        }
        for (name, label) in [("a-h264-ac3.mp4", "AC-3 + MP4"), ("a-h264-eac3.mp4", "E-AC-3 + MP4"),
                              ("a-h264-ac3.ts", "AC-3 + TS"), ("a-h264-eac3.ts", "E-AC-3 + TS"),
                              ("a-h264-flac.mp4", "FLAC + MP4"), ("a-h264-alac.mp4", "ALAC + MP4")] {
            expect(probed[name]?.audioDecodable == true,
                   "\(label):音频轨可解", probed[name]?.exposedSummary ?? "—")
        }
        // ⭐ 实测推翻的假设之三
        let mp3InMP4 = probed["a-h264-mp3.mp4"]
        expect(mp3InMP4?.audioDecodable == true,
               "MP3 + MP4:音频轨可解",
               "文件里 \(actual["a-h264-mp3.mp4"]?.count ?? 0) 种轨型,"
               + "AVFoundation 认下 \(mp3InMP4?.exposedCount ?? 0) 条:[\(mp3InMP4?.exposedSummary ?? "—")]")
        if let mp3File = probed["a-h264-mp3.mp3"] {
            // 单独一个 .mp3 文件是它本来的用法;两个结果要分开记
            expect(mp3File.audioDecodable || !mp3File.opened,
                   "裸 MP3 文件:音频可解", mp3File.exposedSummary)
        }
        for (name, label) in [("a-h264-dts.mp4", "DTS + MP4"), ("a-h264-dts.ts", "DTS + TS"),
                              ("a-h264-truehd.ts", "TrueHD + TS")] {
            let r = probed[name]
            expect(r?.audioDecodable != true, "\(label):音频轨不可解", r?.exposedSummary ?? "—")
            // ⭐ 关键性质:不是「给出一条不可解的轨」,而是**整条轨消失**
            expect(actual[name]?.count != r?.exposedCount,
                   "\(label):不认识的音轨被**静默丢弃**(轨数对不上)",
                   "文件里 \(actual[name]?.count ?? 0) 种轨型 / AVFoundation \(r?.exposedCount ?? 0) 条轨")
        }

        // ============================================== 5. 字幕维
        print("\n== 5. 字幕维:不同字幕格式进不同容器 ==")
        for name in ["s-movtext.mp4", "s-pgs.ts", "s-subrip.ts", "s-vtt.ts", "s-ass.ts",
                     "s-pgs.mkv", "02-multi-track.mkv"] {
            let r = await probe(dir, name)
            probed[name] = r
            report(name, r, actual: actual)
        }
        expect(probed["s-movtext.mp4"]?.legibleOptions.isEmpty == false,
               "mov_text(srt 转 3GPP 定时文本)+ MP4:进 legible 媒体选择组",
               probed["s-movtext.mp4"]?.legibleSummary ?? "—")
        expect(probed["s-pgs.ts"]?.legibleOptions.isEmpty == true,
               "PGS + MPEG-TS:不进 legible 媒体选择组",
               probed["s-pgs.ts"]?.legibleSummary ?? "—")
        for name in ["s-subrip.ts", "s-vtt.ts", "s-ass.ts"] {
            let summary = probed[name]?.legibleSummary ?? "—"
            print("   · \(name) 的 legible 结论:\(summary)")
        }

        // ============================================== 6. 真起播
        print("\n== 6. 真起播:本地 MP4(H.264/AAC) ==")
        await playbackSmoke(dir.appendingPathComponent("base-h264-aac.mp4"))
        await playbackSmoke(dir.appendingPathComponent("v-hevc.ts"))

        // ============================================== 结论
        print("")
        if refuted.isEmpty {
            print("✅ \(checks) 项假设全部与本机实测一致")
        } else {
            print("⚠️ \(refuted.count)/\(checks) 项假设被本机实测推翻,需回填文档与 capability.rs:")
            for r in refuted { print("   · \(r)") }
        }
        exit(0)
    }

    // MARK: - 用真 AVPlayer 起播一次

    private static func playbackSmoke(_ url: URL) async {
        print("   — \(url.lastPathComponent)")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let ready = await waitForReady(item, seconds: 10)
        expect(ready, "\(url.lastPathComponent):10 秒内能 readyToPlay", "status=\(statusText(item.status))")
        guard ready else { return }

        player.play()
        var observed = 0.0
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            observed = max(observed, item.currentTime().seconds)
        }
        print("      播放 4 秒后 currentTime=\(String(format: "%.2f", observed))s"
              + " 状态=\(player.timeControlStatus == .playing ? "playing" : "\(player.timeControlStatus.rawValue)")"
              + " 视频轨暴露=\(item.tracks.contains { $0.assetTrack?.mediaType == .video })")
        expect(observed > 1.0, "\(url.lastPathComponent):播放时刻真的在推进",
               "只走到 \(observed)s")

        // ⚠️ macOS 27 起 `errorLog()`(同步)被弃用,替代是 `fetchErrorLog`。
        //    它的 Swift 名被映射成异步 getter,这里用完成回调 + 续体最稳。
        let log: AVPlayerItemErrorLog? = await withCheckedContinuation { continuation in
            item.fetchErrorLog { continuation.resume(returning: $0) }
        }
        if let log, !log.events.isEmpty {
            for e in log.events { print("      errorLog:\(e.errorComment ?? "") \(e.errorStatusCode)") }
        } else {
            print("      errorLog:无内容")
        }
        if let error = item.error { print("      item.error=\(error)") }
        player.pause()
    }

    private static func statusText(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }

    private static func waitForReady(_ item: AVPlayerItem, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 10) {
            if item.status != .unknown { return item.status == .readyToPlay }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
