import Foundation
import UniformTypeIdentifiers

/// 外挂字幕的**格式口径**(扩展名 / 菜单名 / 文件选择器允许的类型)。
///
/// 单一事实来源:百度同目录配对(`BaiduPanSubtitle`)与手动加载(`SubtitleFileStore`)
/// 认的是同一批格式 —— 两边各写一份迟早分叉(一边加了 vtt、另一边不认)。
///
/// ⛔ `smi` 不在内:libmpv 对它支持不稳,列进来只会多一条加载失败的轨。
enum SubtitleFormats {

    /// 认得的字幕扩展名(小写,不带点)。
    static let fileExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    /// 同一条字幕有多个格式时的挑选优先级(靠前优先)。
    ///
    /// srt 兼容性最好;ASS 带特效但依赖字体;`.sub`(MicroDVD)最老。
    /// ⚠️ 集合必须与 `fileExtensions` 一致 —— 少一个就会把某个格式排到最后而不是拒掉,
    /// 多一个则会挑到挂不上的文件。单测里断言两者相等。
    static let preferredOrder = ["srt", "ass", "ssa", "vtt", "sub"]

    /// **在线下载**时只接受这些格式(比本地导入少一个 `.sub`)。
    ///
    /// 字幕站的 `.sub` 绝大多数是 VobSub 的配套图形文件(与 `.idx` 成对),
    /// 单独交给 mpv 只会失败或满屏乱码;真正的 MicroDVD 纯文本 `.sub` 在站上极少见,
    /// 宁可让它报「换一条」,也不赌一把。
    static let downloadableOrder = ["srt", "ass", "ssa", "vtt"]

    /// 这条文件名是不是字幕(只看扩展名,不看内容)。
    static func isSubtitle(fileName: String) -> Bool {
        fileExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// 菜单里显示的名字:去掉扩展名。空文件名原样返回。
    static func displayName(forFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// `fileImporter` 的允许类型。
    ///
    /// ⚠️ 不按「所有字幕」一刀切:系统没有 `UTType.subtitle`,而 `.sub`(MicroDVD)
    /// 恰恰是老片常见格式、也不属于 `plainText` 的常规集合。逐个扩展名换类型最稳。
    /// 取不到类型时退回 `.data`(选择器不能是空集合,否则面板直接不可用),
    /// 真正的格式闸门在 `SubtitleFileStore` 里按扩展名再判一次。
    static var contentTypes: [UTType] {
        let types = fileExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }
}
