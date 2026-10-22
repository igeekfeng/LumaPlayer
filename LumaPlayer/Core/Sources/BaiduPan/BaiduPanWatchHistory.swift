import Foundation

/// 删掉网盘里的一条后,本地续播库(`WatchProgressStore`)里哪些记录该跟着清,免得「继续观看」留着死卡。
///
/// 判据只有路径包含:`Display.locator` 落在被删路径里(删目录是递归的,`docs/BAIDU_PAN_API.md` §2.4)。
/// ⛔ 不按标题 / 集号猜(可能有同名同集号的文件)。删单个文件只清那一条,同剧其它集留着。
enum BaiduPanWatchHistory {

    /// - Parameters:
    ///   - isDirectory: 目录走递归包含判定,文件只认完全相等。
    ///   - records: 该来源下全部带展示快照的记录(见 `storedRecords`),已看完的也要清。
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
