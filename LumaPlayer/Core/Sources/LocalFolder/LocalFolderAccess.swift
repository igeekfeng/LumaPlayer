import Foundation

/// 本地文件夹的访问权:把安全作用域书签解析成可读 URL,并在本次运行内持有。
///
/// 一个来源只开一次,开到来源被删(`AppContainer.removeSource`)或换文件夹(`AppContainer.relinkLocalFolder`)
/// 才 `close`。⛔ 不要改成「每次读完就关」:libmpv 在别的线程按需读文件、封面也是异步加载,中途关掉就打不开。
actor LocalFolderAccess {

    struct Resolution: Sendable, Equatable {
        let url: URL
        /// 书签陈旧时换出的新书签,调用方要写回注册表;不陈旧为 nil。
        let refreshedBookmark: Data?
    }

    private let bookmarks: any LocalFolderBookmarking
    private var opened: [UUID: URL] = [:]

    init(bookmarks: any LocalFolderBookmarking = SecurityScopedBookmarks()) {
        self.bookmarks = bookmarks
    }

    /// 已打开且目录还在就复用;目录没了(外接盘拔了)就关掉重新解析,以便跟上新挂载点。
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
        // 陈旧书签这次还能用;换不出新书签也不挡访问,下次启动再试
        let refreshed = resolved.isStale ? try? bookmarks.makeBookmark(for: resolved.url) : nil
        return Resolution(url: resolved.url, refreshedBookmark: refreshed)
    }

    /// 没打开过就什么都不做。
    func close(sourceID: UUID) {
        guard let url = opened.removeValue(forKey: sourceID) else { return }
        bookmarks.stopAccessing(url)
    }

    /// 给刚选中的文件夹做书签。`fileImporter` 给的 URL 要先 `startAccessing` 才读得到,这里包一层。
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

/// 抽出来只为测试:沙盒里对临时目录做安全作用域书签的行为与真实选择的文件夹不同。
protocol LocalFolderBookmarking: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func isReachableDirectory(_ url: URL) -> Bool
}

/// 安全作用域、只读书签(见 `FileSource.supportsDeletingFiles`)。
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
