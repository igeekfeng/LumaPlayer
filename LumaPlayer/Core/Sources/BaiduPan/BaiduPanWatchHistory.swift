import Foundation

/// 「删掉网盘里的这一条,本地续播库里哪些记录也该跟着没」——纯函数,单测覆盖。
///
/// ## 为什么需要它
///
/// 百度来源的进度存在本地续播库(`WatchProgressStore`),而「继续观看」区
/// 是从那个库里折出来的卡片。网盘里的文件删掉了,库里那几条记录还在 ——
/// 于是「继续观看」里会留着一张**点开就播不了**的卡(播放时才发现文件
/// 已经不存在)。删除是不可恢复的操作,留一条指向死文件的记录没有任何意义。
///
/// ## 判据只有「路径包含」
///
/// 记录里能定位文件的只有 `Display.locator`(播放那一刻的网盘路径),
/// 而删除接口按路径删(`docs/BAIDU_PAN_API.md` §2.4,删目录是**递归**的)。
/// 两者对得上才是同一条 —— ⛔ 不按标题 / 集号猜:同一目录下同名同集号
/// 的两条文件是可能存在的,猜错就是删错了别人的进度。
///
/// ⚠️ 只对**路径真的落在被删目录里**的记录生效。删单个文件时只清那一条,
/// 同剧其它集的记录留着(卡会退到下一集,那正是「接着看」该有的样子)。
enum BaiduPanWatchHistory {

    /// 删掉 `path` 之后,`records` 里**属于它**的那些记录的 `fileID`。
    ///
    /// - Parameters:
    ///   - path: 被删的网盘路径(文件或目录)。
    ///   - isDirectory: 删的是不是目录。目录走递归包含判定,文件只认完全相等。
    ///   - records: 该来源下**全部**带展示快照的记录(见 `storedRecords`)。
    ///     这里不过滤「已看完」—— 那些也在库里,也得一起清。
    static func fileIDs(
        deletingPath path: String,
        isDirectory: Bool,
        from records: [WatchProgressStore.StoredRecord]
    ) -> [String] {
        guard !path.isEmpty else { return [] }
        return records
            .filter { BaiduPanPath.covers(
                path: path, locator: $0.display.locator, isDirectory: isDirectory) }
            .map(\.fileID)
    }
}
