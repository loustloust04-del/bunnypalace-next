import XCTest
import MemoryCore
@testable import memoryd

/// 内置题集有两份（app 的 `Resources/MemoryBench` 和 memoryd 的 `MemoryBench`）：SwiftPM 资源不能引用包外路径，只能靠测试守住
final class MemorydBuiltInSetsParityTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MemorydTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MemoryCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // 仓库根
    }

    func testBuiltInSetsMatchAppResources() throws {
        for name in MemoryBenchStore.builtInSetNames {
            let app = repoRoot.appendingPathComponent("MemoryPalace/Resources/MemoryBench/\(name).json")
            let memoryd = repoRoot.appendingPathComponent("Packages/MemoryCore/Sources/memoryd/MemoryBench/\(name).json")
            XCTAssertEqual(try Data(contentsOf: app), try Data(contentsOf: memoryd), "\(name).json 两份漂了")
        }
        // recall 的内置楼层：app 资源 == memoryd 资源 == 包测试夹具
        let name = "memory-bench-recall-floor-xingyan"
        let app = repoRoot.appendingPathComponent("MemoryPalace/Resources/MemoryBench/\(name).json")
        let memoryd = repoRoot.appendingPathComponent("Packages/MemoryCore/Sources/memoryd/MemoryBench/\(name).json")
        let fixture = repoRoot.appendingPathComponent("Packages/MemoryCore/Tests/MemoryCoreTests/Fixtures/conversation-floor-schema1.json")
        let bytes = try Data(contentsOf: app)
        XCTAssertEqual(bytes, try Data(contentsOf: memoryd), "\(name).json 两份漂了")
        XCTAssertEqual(bytes, try Data(contentsOf: fixture), "\(name).json 与包夹具漂了")
    }
}

/// `scripts/memoryd-mount.sh`：private_* 不分大小写、链接不拷、dst 在 src 里拒绝、写挂载标记
final class MemorydMountScriptTests: XCTestCase {
    private var temp: URL!
    private var src: URL!
    private var dst: URL!

    private var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/memoryd-mount.sh")
    }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("memoryd-mount-\(UUID().uuidString)", isDirectory: true)
        src = temp.appendingPathComponent("src floor", isDirectory: true)
        dst = temp.appendingPathComponent("copy dir/memory", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("wiki/人", isDirectory: true), withIntermediateDirectories: true)
        try "星砚".write(to: src.appendingPathComponent("wiki/人/星砚.md"), atomically: true, encoding: .utf8)
        try "大写".write(to: src.appendingPathComponent("wiki/人/Private_大写.md"), atomically: true, encoding: .utf8)
        try "小写".write(to: src.appendingPathComponent("wiki/人/private_小写.md"), atomically: true, encoding: .utf8)
        try "外部".write(to: temp.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: src.appendingPathComponent("wiki/人/链页.md"),
                                  withDestinationURL: temp.appendingPathComponent("outside.md"))
        try "x".write(to: src.appendingPathComponent(".recall-index.sqlite"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testCopiesWithoutPrivateLinksOrIndex() throws {
        let result = try run([src.path, dst.path])
        XCTAssertEqual(result.status, 0, result.output)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("wiki/人/星砚.md").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("wiki/人/Private_大写.md").path), "大写 Private_ 也不拷")
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("wiki/人/private_小写.md").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("wiki/人/链页.md").path), "链接不拷")
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent(".recall-index.sqlite").path))
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent(MemorydService.mountMarkerName).path), "要留挂载标记")
        XCTAssertTrue(result.output.contains("复制 1 个文件"), "标记不算拷来的文件：\(result.output)")
        XCTAssertTrue(result.output.contains("跳过 private_* 2 个"), result.output)
        XCTAssertTrue(result.output.contains("跳过链接 1 个"), result.output)
    }

    /// E2-6：`exports/`（楼层快照）随整目录一起拷进副本
    func testCopiesExportsFolder() throws {
        let fm = FileManager.default
        let src = temp.appendingPathComponent("src snapshot", isDirectory: true)
        let dst = temp.appendingPathComponent("copy snapshot/memory", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent("exports", isDirectory: true), withIntermediateDirectories: true)
        try "{}".write(to: src.appendingPathComponent("exports/floor-snapshot-20261108-080000Z.json"),
                       atomically: true, encoding: .utf8)
        let result = try run([src.path, dst.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("exports/floor-snapshot-20261108-080000Z.json").path),
                      "楼层快照要能到副本里给 memoryd 认")
    }

    func testRefusesDestinationInsideSource() throws {
        let inside = src.appendingPathComponent("nested/deeper/memory", isDirectory: true)
        let result = try run([src.path, inside.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("nested").path),
                       "拒绝时不能先往源里建目录")
    }

    /// N3：路径按物理路径比较，`/tmp` 和 `/private/tmp` 两种写法交叉也要拒绝
    func testRefusesSymlinkedPathIntoSource() throws {
        let fm = FileManager.default
        let name = "memoryd-mount-symlink-\(UUID().uuidString)"
        let linkSrc = URL(fileURLWithPath: "/tmp/\(name)/src", isDirectory: true)
        let realSrc = URL(fileURLWithPath: "/private/tmp/\(name)/src", isDirectory: true)
        try fm.createDirectory(at: linkSrc.appendingPathComponent("wiki"), withIntermediateDirectories: true)
        try "页".write(to: linkSrc.appendingPathComponent("wiki/a.md"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)) }

        let linkIntoReal = try run([linkSrc.path, realSrc.appendingPathComponent("inner").path])
        XCTAssertNotEqual(linkIntoReal.status, 0, "源写 /tmp、副本写 /private/tmp/" + linkIntoReal.output)
        XCTAssertFalse(fm.fileExists(atPath: realSrc.appendingPathComponent("inner").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: realSrc.path).sorted(), ["wiki"])

        let realIntoLink = try run([realSrc.path, linkSrc.appendingPathComponent("inner").path])
        XCTAssertNotEqual(realIntoLink.status, 0, "源写 /private/tmp、副本写 /tmp/" + realIntoLink.output)
        XCTAssertFalse(fm.fileExists(atPath: realSrc.appendingPathComponent("inner").path))
    }
}
