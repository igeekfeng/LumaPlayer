import Foundation
import mpv

/// 容器里的一条章节(`chapter-list/N`,MPV_INTEGRATION.md 7.3),只解用得到的两个字段。
///
/// ⛔ 与 Emby 的 `Chapters` 不是一回事:那是服务端给的片头 / 片尾标记(`PlaybackMarkers`),
/// 这里读的是**播放内核看到的**章节 —— 本地文件夹与百度网盘的文件同样有。
struct MPVChapter: Sendable, Equatable, Identifiable {
    /// 列表下标(从 0 起)。跳转按 `time` 走,⛔ 不用 mpv 的 `chapter` 属性:
    /// 那是在核心里 seek,转码流必须由客户端重新起流(API_CONTRACT.md 4.5)。
    let index: Int
    /// 起点(秒)
    let time: Double
    /// 容器里的标题;没有或全是空白时为 nil
    let title: String?

    var id: Int { index }

    /// title →「第 N 章」,⛔ 不显示空串。
    var displayName: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return "第 \(index + 1) 章"
    }

    /// 位置落在哪一章:取不晚于 `position` 的最后一条(纯函数,单测直接验)。
    /// ⛔ 不加容差:容差会让播放头刚进本章就显示成下一章。
    static func current(at position: Double, in chapters: [MPVChapter]) -> MPVChapter? {
        guard position.isFinite else { return nil }
        return chapters.last { $0.time <= position }
    }
}

// MARK: - chapter-list 节点解析

/// `chapter-list` 的 `mpv_node` 解析。规则与 `MPVTrackListParser` 相同:
/// 事件里的节点归 mpv,下一次 `mpv_wait_event()` 自动释放,⛔ 不得 `mpv_free_node_contents`,
/// 必须同步解析完、不持有指针。
enum MPVChapterListParser {
    static func parse(_ node: inout mpv_node) -> [MPVChapter] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { return [] }
        let count = Int(list.pointee.num)
        guard let values = list.pointee.values else { return [] }
        var chapters: [MPVChapter] = []
        chapters.reserveCapacity(count)
        for index in 0..<count {
            let entry = values[index]
            guard entry.format == MPV_FORMAT_NODE_MAP, let map = entry.u.list else { continue }
            let fields = map.pointee
            let fieldCount = Int(fields.num)
            var title: String?
            var time: Double?
            for field in 0..<fieldCount {
                guard let key = fields.keys?[field] else { continue }
                let value = fields.values?[field]
                switch String(cString: key) {
                case "title":
                    if value?.format == MPV_FORMAT_STRING, let raw = value?.u.string {
                        title = String(cString: raw)
                    }
                case "time":
                    // 节点里的 time 是 double(client.h `mpv_node` 的 `u.double_`)
                    if value?.format == MPV_FORMAT_DOUBLE {
                        time = value?.u.double_
                    }
                default:
                    break
                }
            }
            // 没有时间的章节跳不过去,整条丢掉(⛔ 不拿 0 顶上)
            guard let time, time.isFinite, time >= 0 else { continue }
            chapters.append(MPVChapter(index: index, time: time, title: title))
        }
        return chapters
    }
}
