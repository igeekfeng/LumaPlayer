import Foundation
import XCTest

/// 读取 `Fixtures/` 下的脱敏 fixture(API_CONTRACT.md 第 9 节)。
/// `_synthetic` 后缀 = 构造数据、未经真实服务器验证;无后缀 = 真实响应按 9.3 脱敏。
enum FixtureLoader {
    private final class BundleMarker {}

    /// 子目录在测试 bundle 里可能被展平:先按 resource 名找,再递归搜。
    static func json(_ fileName: String) throws -> String {
        String(data: try data(fileName), encoding: .utf8) ?? ""
    }

    static func data(_ fileName: String) throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        if let url = bundle.url(forResource: fileName, withExtension: nil) {
            return try Data(contentsOf: url)
        }
        if let url = recursiveFind(fileName, in: bundle) {
            return try Data(contentsOf: url)
        }
        XCTFail("找不到 fixture \(fileName);确认它已加入 LumaPlayerTests target 的 Resources")
        throw FixtureError.notFound(fileName)
    }

    private static func recursiveFind(_ fileName: String, in bundle: Bundle) -> URL? {
        let rootURL = URL(fileURLWithPath: bundle.resourcePath ?? bundle.bundlePath)
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == fileName {
                return url
            }
        }
        return nil
    }
}

enum FixtureError: Error, Equatable {
    case notFound(String)
}
