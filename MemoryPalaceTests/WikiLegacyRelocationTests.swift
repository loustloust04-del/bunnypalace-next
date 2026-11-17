import MemoryCore
import XCTest
@testable import 记忆花园

/// 启动挂钩：旧摆法 `楼层/…` 的页搬到现在的位置，搬了才记一行日志（数据全是编的）
@MainActor
final class WikiLegacyRelocationTests: XCTestCase {
    private var pid = ""

    override func setUp() async throws {
        pid = "xctest-wiki-legacy-" + UUID().uuidString
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        let pid = pid
        await Task.detached { try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()) }.value
    }

    private func notes() async -> [MemoryWriteLog.Entry] {
        let pid = pid
        return await Task.detached {
            MemoryWriteLog.flush()
            return MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        }.value
    }

    func testLaunchHookMovesLegacyPagesAndLogsCountsOnce() async throws {
        let pid = pid
        try await Task.detached {
            let legacy = WikiStore(profileId: pid).root.appendingPathComponent("楼层", isDirectory: true)
            for (path, kind) in [("岚舟/皮影收藏", WikiPage.Kind.user), ("地点/云桥城", .place), ("星砚/旧事", .topic)] {
                let url = legacy.appendingPathComponent(path + ".md")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(WikiPage(path: "楼层/" + path, kind: kind, title: String(path.split(separator: "/")[1])).markdown.utf8).write(to: url)
            }
        }.value

        await WikiStore.relocateLegacyLayout(profileId: pid, user: "岚舟")

        let pages = await Task.detached {
            SafeWiki.scan(WikiStore(profileId: pid), memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).pages.map(\.path)
        }.value
        XCTAssertEqual(pages, ["地点/云桥城", "{{user}}/皮影收藏"].sorted())
        var log = await notes()
        XCTAssertEqual(log.map(\.note), ["wiki 旧位置的 2 页搬到了现在的位置；1 页没搬（认不出该放哪一组 1）"])
        XCTAssertEqual(log.first?.writer, MemoryWriterID.c3.code)
        XCTAssertEqual(log.first?.ok, true)

        await WikiStore.relocateLegacyLayout(profileId: pid, user: "岚舟")
        log = await notes()
        XCTAssertEqual(log.count, 1, "第二遍什么都没搬，不再记")
    }

    func testFloorWithoutLegacyFolderLogsNothing() async throws {
        let pid = pid
        try await Task.detached { try WikiStore(profileId: pid).save(WikiPage(path: "地点/云桥城", kind: .place, title: "云桥城")) }.value

        await WikiStore.relocateLegacyLayout(profileId: pid, user: "岚舟")

        let log = await notes()
        XCTAssertEqual(log, [])
    }
}
