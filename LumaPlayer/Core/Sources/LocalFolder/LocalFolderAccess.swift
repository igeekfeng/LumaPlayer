import Foundation

/// 本地文件夹的**访问权**:把来源里存的安全作用域书签解析成可读的 URL,并在本次运行内持有。
///
/// ## 为什么持有到来源被删 / 换文件夹为止
///
/// `startAccessingSecurityScopedResource()` 打开的访问权要成对 `stop`。按「每次读目录
/// 开一次、读完关掉」来管理看着整洁,但播放内核(libmpv)是**另一条线程上**按需读文件的,
/// 浏览页的封面加载也是异步的 —— 任何一方读的时候访问权恰好被关掉,就是一次莫名其妙的
/// 「打不开」。所以这里一个来源只开一次,开着直到:
/// - 来源被删(`AppContainer.removeSource` → `close`);
/// - 换了文件夹(`AppContainer.relinkLocalFolder` → `close`,下次再按新书签打开)。
///
/// 内核对同时打开的作用域数量有上限,但这里是「一个来源一个」,远到不了。
actor LocalFolderAccess {

    /// 一次解析的结果。
    struct Resolution: Sendable, Equatable {
        let url: URL
        /// 系统报书签**陈旧**时换出来的新书签(调用方要写回注册表);不陈旧为 nil。
        let refreshedBookmark: Data?
    }

    private let bookmarks: any LocalFolderBookmarking
    /// 已经打开访问权的来源 → 解析出的根 URL
    private var opened: [UUID: URL] = [:]

    init(bookmarks: any LocalFolderBookmarking = SecurityScopedBookmarks()) {
        self.bookmarks = bookmarks
    }

    /// 来源的根目录 URL(访问权已打开)。
    ///
    /// 已经打开过、且目录还在就直接复用;目录没了(外接盘拔了)就关掉重来 ——
    /// 再插上时书签能重新解析到新的挂载点。
    func rootURL(for source: LocalFolderSource) throws -> Resolution {
        if let url = opened[source.id] {
            if bookmarks.isReachableDirectory(url) {
                return Resolution(url: url, refreshedBookmark: nil)
            }
            close(sourceID: source.id)
        }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarks.resolve(source.bookmark)
        } catch {
            throw LocalFolderError.folderUnavailable(path: source.lastKnownPath)
        }
        guard bookmarks.startAccessing(resolved.url) else {
            throw LocalFolderError.accessDenied(path: resolved.url.path)
        }
        guard bookmarks.isReachableDirectory(resolved.url) else {
            bookmarks.stopAccessing(resolved.url)
            throw LocalFolderError.folderUnavailable(path: resolved.url.path)
        }
        opened[source.id] = resolved.url
        // 陈旧书签还能用这一次,但系统要求换一份新的存起来 —— 换不出来也不挡这一次访问,
        // 下次启动会再报陈旧、再试一次(⛔ 不为此打断浏览)
        let refreshed = resolved.isStale ? try? bookmarks.makeBookmark(for: resolved.url) : nil
        return Resolution(url: resolved.url, refreshedBookmark: refreshed)
    }

    /// 关掉这个来源的访问权(来源被删 / 换了文件夹)。没打开过就什么都不做。
    func close(sourceID: UUID) {
        guard let url = opened.removeValue(forKey: sourceID) else { return }
        bookmarks.stopAccessing(url)
    }

    /// 给刚选中的文件夹做书签。
    ///
    /// ⚠️ 调用方传进来的是打开面板 / `fileImporter` 给的 URL:它本身就带着本次运行的访问权,
    /// 但 `fileImporter` 给的那种要先 `startAccessing` 才读得到 —— 这里包一层,两种都能用。
    func makeBookmark(forFolderAt url: URL) throws -> Data {
        let started = bookmarks.startAccessing(url)
        defer { if started { bookmarks.stopAccessing(url) } }
        guard bookmarks.isReachableDirectory(url) else {
            throw LocalFolderError.folderUnavailable(path: url.path)
        }
        do {
            return try bookmarks.makeBookmark(for: url)
        } catch {
            throw LocalFolderError.bookmarkCreationFailed(error.localizedDescription)
        }
    }
}

/// 书签的几个系统调用。抽出来只为测试:单测跑在宿主 App 的沙盒里,
/// 对临时目录做安全作用域书签的行为与真实用户选的文件夹不同,测试换成直通实现。
protocol LocalFolderBookmarking: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func isReachableDirectory(_ url: URL) -> Bool
}

/// 生产实现:安全作用域、**只读**书签(本地文件夹来源不做写操作,见 `FileSource.supportsDeletingFiles`)。
struct SecurityScopedBookmarks: LocalFolderBookmarking {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    func isReachableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
