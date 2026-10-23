import XCTest
@testable import 记忆花园

/// #028 B1：iOS 真机枚举器给 `/private/var/…`、根是 `/var/…`，以前前缀永远不中、逐文件 standardizedFileURL。
/// 现在根的两种写法各算一次；相对路径必须和老算法逐字一致。
final class FileLibraryRootPrefixTests: XCTestCase {

    /// 改动前的 relativeToRoot，只用来对照
    private func legacy(_ url: URL, rootPath: String) -> String {
        let path = url.path
        if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
        let std = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return String(url.standardizedFileURL.path.dropFirst(std.count + 1))
    }

    func testPrefixCombinations() {
        let cases: [(root: String, path: String, want: String?)] = [
            ("/var/mobile/X/记忆宫殿/floors/主楼/filesystem", "/private/var/mobile/X/记忆宫殿/floors/主楼/filesystem/笔记/a b.md", "笔记/a b.md"),
            ("/var/mobile/X/fs", "/var/mobile/X/fs/a.md", "a.md"),
            ("/private/var/mobile/X/fs", "/var/mobile/X/fs/dir/c.txt", "dir/c.txt"),
            ("/private/var/mobile/X/fs", "/private/var/mobile/X/fs/c.txt", "c.txt"),
            ("/Users/susu/Library/Containers/com.susu.MemoryPalace/Data/Documents/fs", "/Users/susu/Library/Containers/com.susu.MemoryPalace/Data/Documents/fs/x/y.md", "x/y.md"),
            ("/var/mobile/X/fs", "/var/mobile/X/fsother/a.md", nil),
            ("/var/mobile/X/fs", "/private/var/mobile/X/fsother/a.md", nil),
            ("/var/mobile/X/fs", "/var/mobile/X/fs", nil),
            ("/var/mobile/X/fs", "/private/var/mobile/X/fs", nil),
            ("/var/mobile/X/fs", "/private/private/var/mobile/X/fs/a", nil),
            ("/tmp/x/fs", "/private/tmp/x/fs/a.md", "a.md"),
            ("/private/etc/x", "/etc/x/a.md", "a.md"),
            // sol 反例：别名命中但尾部要规整 → 不走快路（交给老算法）
            ("/var/R", "/private/var/R/d/../a.md", nil),
            ("/var/R", "/private/var/R/./a.md", nil),
            ("/var/R", "/private/var/R//a.md", nil),
            ("/var/R", "/private/var/R/d/..", nil),
            ("/var/R", "/private/var/R/d/.", nil),
            // sol 反例：非系统链接根（含 mac 沙盒）不生成别名
            ("/opt/lib", "/private/opt/lib/a.md", nil),
            ("/Users/susu/Library/Containers/com.susu.MemoryPalace/Data/Documents/fs", "/private/Users/susu/Library/Containers/com.susu.MemoryPalace/Data/Documents/fs/a.md", nil),
            ("/variant/x", "/private/variant/x/a.md", nil),
            // 原样前缀快路保持老行为
            ("/var/R", "/var/R/d/../a.md", "d/../a.md"),
        ]
        for c in cases {
            XCTAssertEqual(FileLibraryStore.RootPrefix(rootPath: c.root).relative(c.path), c.want, "\(c.root) | \(c.path)")
        }
    }

    /// mac 上 /var → /private/var，和真机同构：枚举 /private 形态、根 /var 形态（及反过来），逐个对照老算法
    func testMatchesLegacyOnRealDisk() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.path
        try XCTSkipUnless(tmp.hasPrefix("/var/"), "temporaryDirectory 不在 /var：\(tmp)")
        let base = tmp + "/xctest-rootprefix-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        let rootVar = base + "/记忆宫殿/floors/主 楼/filesystem"
        try fm.createDirectory(atPath: rootVar + "/books/某本书", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rootVar + "/文件夹 一/sub", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rootVar + "/d", withIntermediateDirectories: true)
        for p in ["readme.md", "books/某本书/ch1.md", "文件夹 一/sub/n o t e.md", "文件夹 一/é.md"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: rootVar + "/" + p))
        }
        let rootPriv = "/private" + rootVar
        try fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: rootVar)

        let combos: [(enumAt: String, rootPath: String, fast: Bool)] = [
            (rootPriv, rootVar, true),
            (rootVar, rootPriv, true),
            (rootVar, rootVar, true),
            (rootPriv, base + "/link", false),
        ]
        for combo in combos {
            let prefix = FileLibraryStore.RootPrefix(rootPath: combo.rootPath)
            let en = try XCTUnwrap(fm.enumerator(at: URL(fileURLWithPath: combo.enumAt), includingPropertiesForKeys: nil))
            var n = 0
            for case let url as URL in en {
                n += 1
                XCTAssertEqual(FileLibraryStore.relativeToRoot(url, root: prefix), legacy(url, rootPath: combo.rootPath), url.path)
                XCTAssertEqual(prefix.relative(url.path) != nil, combo.fast, url.path)
            }
            XCTAssertEqual(n, 9, combo.enumAt)
        }

        // sol 反例 1 真盘版：/private 别名 + `..` / `.` / `//` 不走快路，回退结果同老算法
        let prefix = FileLibraryStore.RootPrefix(rootPath: rootVar)
        for tail in ["/d/../readme.md", "/./readme.md", "//readme.md"] {
            let url = URL(fileURLWithPath: rootPriv + tail)
            XCTAssertNil(prefix.relative(url.path), tail)
            XCTAssertEqual(FileLibraryStore.relativeToRoot(url, root: prefix), legacy(url, rootPath: rootVar), tail)
            XCTAssertEqual(FileLibraryStore.relativeToRoot(url, root: prefix), "readme.md", tail)
        }
    }
}
