import Foundation
import UniformTypeIdentifiers

/// 外挂字幕格式的唯一口径,百度同目录配对与手动加载共用。
/// ⛔ 不收 `smi`:libmpv 支持不稳。
enum SubtitleFormats {

    /// 小写,不带点
    static let fileExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    /// 多格式时的挑选优先级(靠前优先)。⚠️ 集合必须与 `fileExtensions` 一致(单测断言)。
    static let preferredOrder = ["srt", "ass", "ssa", "vtt", "sub"]

    /// 在线下载只收这些(比本地导入少 `.sub`):字幕站的 `.sub` 几乎都是 VobSub 配套图形文件
    /// (与 `.idx` 成对),单独交给 mpv 只会失败。
    static let downloadableOrder = ["srt", "ass", "ssa", "vtt"]

    /// 只看扩展名
    static func isSubtitle(fileName: String) -> Bool {
        fileExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// 去掉扩展名;结果为空时原样返回。
    static func displayName(forFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// `fileImporter` 的允许类型。系统没有 `UTType.subtitle`,逐个扩展名换类型;
    /// 全取不到时退回 `.data`(空集合会让面板不可用)。真正的闸门在 `SubtitleFileStore`。
    static var contentTypes: [UTType] {
        let types = fileExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }
}
