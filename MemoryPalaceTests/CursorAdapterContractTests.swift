#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-b Cursor：逐条照抄 Wake `cursor_parse_contract` + 全局 seq 契约 + slug 反推 / 时间串解析
final class CursorAdapterContractTests: XCTestCase {
    private var root: URL { CodingSessionAdapterTests.fixtures.appendingPathComponent("cursor/projects") }

    func testCursorParseContract() throws {
        let adapter = CursorAdapter(root: root)
        let ref = try XCTUnwrap(adapter.listSessionFiles().first)
        XCTAssertEqual(ref.nativeId, "33333333-aaaa-bbbb-cccc-000000000003")
        let s = try adapter.parseSession(ref)
        let t = try adapter.parseTranscript(ref)

        XCTAssertEqual(s.meta.title, "把二维码扫描组件抽出来,注意 useEffect() 的清理", "标题取 <user_query> 壳内正文；<workspace> 注入行归 Meta")
        XCTAssertEqual(s.meta.projectPath, "/wakefx/cursor/proj", "slug 在磁盘上无对应真实路径 → 直译回退")
        XCTAssertEqual(s.meta.projectName, "proj")
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-01T09:30:00+08:00"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-01T09:40:00+08:00"))
        XCTAssertEqual(s.meta.messageCount, 3)
        XCTAssertEqual(s.unknownLines, 1, "session_started；turn_ended 不计")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/meta", "user/text", "assistant/text", "user/text"],
                       "连续 assistant 行合并")
        XCTAssertEqual(t.mainline[1].timestamp, CodingContract.ms("2026-08-01T09:30:00+08:00"))
        let assistant = t.mainline[2]
        XCTAssertEqual(assistant.toolCalls.count, 1)
        XCTAssertEqual(assistant.toolCalls.first?.name, "read_file")
        XCTAssertNil(assistant.toolCalls.first?.output, "transcript 不落盘工具结果")
        XCTAssertEqual(s.units.map(\.seq), [1, 2, 3])
        try CodingContract.assertSeqContract(adapter, ref)
        XCTAssertEqual(adapter.sessionPaths(s.meta), [URL(fileURLWithPath: ref.filePath).deletingLastPathComponent().path], "删整个会话目录")
    }

    func testTimestampAndSlugDecoding() throws {
        XCTAssertEqual(CursorAdapter.timestampMs("Thursday, Jul 23, 2026, 4:00 PM (UTC+8)"), CodingContract.ms("2026-07-23T16:00:00+08:00"))
        XCTAssertEqual(CursorAdapter.timestampMs("Saturday, Aug 01, 2026, 9:30 AM (UTC+08:00)"), CodingContract.ms("2026-08-01T09:30:00+08:00"))
        XCTAssertEqual(CursorAdapter.timestampMs("Monday, Jan 5, 2026, 12:05 AM (UTC-5)"), CodingContract.ms("2026-01-05T00:05:00-05:00"))
        XCTAssertEqual(CursorAdapter.timestampMs("Sat, Aug 1, 2026, 9:30 am (UTC+8)"), CodingContract.ms("2026-08-01T09:30:00+08:00"), "星期缩写 / 小写上下午")
        XCTAssertEqual(CursorAdapter.timestampMs("Friday, Aug 01, 2026, 9:30 AM (UTC+8)"), 0, "星期与日期对不上 = 解析失败（chrono 同）")
        XCTAssertEqual(CursorAdapter.timestampMs("Saturday, Aug 01, 2026, 9:30 AM (UTC)"), 0, "无偏移 = 失败")
        XCTAssertEqual(CursorAdapter.timestampMs("garbage"), 0)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-cursor-slug-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("image-translate")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let canonical = CodingParse.canonicalPath(real.path)
        let slug = String(canonical.dropFirst()).replacingOccurrences(of: "/", with: "-")
        XCTAssertEqual(CursorAdapter.decodeSlug(slug), canonical, "按磁盘真实目录 DFS：目录名里的 - 不当分隔符")
        XCTAssertEqual(CursorAdapter.decodeSlug("no-such-dir-here"), "/no/such/dir/here")
    }

    func testSubagentFilesAreNotSessions() {
        let adapter = CursorAdapter(root: root)
        XCTAssertNil(adapter.fileRef(URL(fileURLWithPath: "/x/.cursor/projects/p/agent-transcripts/u/subagents/a.jsonl")))
        XCTAssertEqual(CursorAdapter(home: URL(fileURLWithPath: "/h")).root.path, "/h/.cursor/projects")
        XCTAssertTrue(CursorAdapter(home: URL(fileURLWithPath: "/nonexistent")).listSessionFiles().isEmpty, "缺根降级为空")
    }
}
#endif
