import XCTest
import SwiftData
@testable import 记忆花园

final class CatalogRunRecordTests: XCTestCase {
    func testOrderedTranscriptPreservesFullTextAndCanResolveRound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let run = CatalogRunRecord(wiki: wiki, topic: "电影/主题", kind: "测试")
        let body = String(repeating: "完整的工具返回。", count: 2000) + "\n```json\n{\"terms\":[\"电影\"]}\n```"
        let anchor = run.section("第 1 轮", body: CatalogRunRecord.code(body))
        run.section("第 2 轮", body: "收到 1 条")
        await run.flush()
        let text = try String(contentsOf: run.url, encoding: .utf8)
        XCTAssertTrue(text.contains(body), "不能复用草稿的长度上限而截掉运行记录")
        XCTAssertTrue(text.contains("<a id=\"\(anchor)\"></a>"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "## 第 1 轮")?.lowerBound), try XCTUnwrap(text.range(of: "## 第 2 轮")?.lowerBound))
        XCTAssertEqual(CatalogRunRecord.resolve(run.link(anchor: anchor), wiki: wiki), run.url)
        XCTAssertTrue(text.contains("````\n" + body + "\n````"), "原文含围栏时使用更长围栏")
    }

    func testRetentionAndInvalidLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let now = Date()
        let old = CatalogRunRecord(wiki: wiki, topic: "旧记录", kind: "测试", now: now.addingTimeInterval(-31 * 86_400))
        await old.flush()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: old.url.path)
        let recent = CatalogRunRecord(wiki: wiki, topic: "新记录", kind: "测试", now: now)
        await recent.flush()
        XCTAssertNil(CatalogRunRecord.resolve(old.link(), wiki: wiki))
        XCTAssertEqual(CatalogRunRecord.resolve(recent.link(), wiki: wiki), recent.url)
        for path in ["../secret.md", ".runs/../secret.md", ".proposals/a.json", ".runs/secret.txt"] {
            XCTAssertNil(CatalogRunRecord.resolve(.init(path: path), wiki: wiki))
        }
        let escape = wiki.root.appendingPathComponent(".runs/escape.md")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: recent.url)
        XCTAssertNil(CatalogRunRecord.resolve(.init(path: ".runs/escape.md"), wiki: wiki))
    }

    func testStructuredLogLinkRoundTripAndLegacyEntry() throws {
        let link = CatalogRunLink(path: ".runs/example.md", anchor: "round-3")
        let entry = MemoryWriteLog.Entry(time: Date(timeIntervalSince1970: 1), writer: "C3", ok: true,
                                         note: "正文不参与定位", model: "fake", run: link)
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(MemoryWriteLog.Entry.self, from: data).run, link)
        let legacy = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"time\":1,\"writer\":\"C3\",\"ok\":true,\"note\":\"旧日志\",\"model\":\"fake\"}"
        XCTAssertNil(try JSONDecoder().decode(MemoryWriteLog.Entry.self, from: Data(legacy.utf8)).run)
    }

    func testLogConsumerOpensStructuredFileAndRoundInsteadOfParsingNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let first = CatalogRunRecord(wiki: wiki, topic: "电影", kind: "测试")
        let one = first.section("第 1 轮", body: "第一轮原文")
        let two = first.section("第 2 轮", body: "第二轮原文")
        let second = CatalogRunRecord(wiki: wiki, topic: "另一次电影", kind: "测试")
        second.section("第 1 轮", body: "另一份记录")
        await first.flush()
        await second.flush()

        for link in [first.link(anchor: one), first.link(anchor: two), first.link(), second.link()] {
            let entry = MemoryWriteLog.Entry(time: Date(), writer: "C3", ok: true,
                                             note: "第 999 轮：.runs/不是目标.md", model: "fake", run: link)
            let result = await MemoryWriteLogRunReader.load(entry, wiki: wiki) { url in
                XCTAssertFalse(Thread.isMainThread, "resolve/read 不能在主线程执行")
                return try String(contentsOf: url, encoding: .utf8)
            }
            guard case .loaded(let document) = result else { return XCTFail("关联日志应打开记录") }
            XCTAssertEqual(document.link, link)
            XCTAssertEqual(document.url, link.path == first.relativePath ? first.url : second.url)
            XCTAssertEqual(document.content, try String(contentsOf: document.url, encoding: .utf8))
            let location = FileEditorPreviewLocation(content: document.content, anchor: document.link.anchor)
            XCTAssertEqual(location.parts.joined(), document.content, "定位不能裁掉前后文")
            if let anchor = link.anchor {
                let index = try XCTUnwrap(location.targetIndex)
                XCTAssertTrue(location.parts[index].hasPrefix("<a id=\"\(anchor)\"></a>"))
                XCTAssertTrue(location.parts[index].contains(anchor == one ? "第一轮原文" : "第二轮原文"))
            } else {
                XCTAssertNil(location.targetIndex, "没有轮次的汇总从全文开头看")
            }
        }
    }

    func testLogConsumerReportsExpiredBeforeAndDuringRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let run = CatalogRunRecord(wiki: wiki, topic: "已删除", kind: "测试")
        await run.flush()
        let entry = MemoryWriteLog.Entry(time: Date(), writer: "C3", ok: true, note: "", model: "", run: run.link())
        let duringRead = await MemoryWriteLogRunReader.load(entry, wiki: wiki) { url in
            XCTAssertFalse(Thread.isMainThread)
            try FileManager.default.removeItem(at: url)
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(duringRead.message, CatalogRunRecord.expiredMessage)
        let alreadyDeleted = await MemoryWriteLogRunReader.load(entry, wiki: wiki)
        XCTAssertEqual(alreadyDeleted.message, CatalogRunRecord.expiredMessage)
    }

    func testLegacyAndNonC3LogRowsDoNotTryOpeningRecords() async {
        let wiki = WikiStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for entry in [
            MemoryWriteLog.Entry(time: Date(), writer: "C3", ok: true, note: "第 3 轮", model: ""),
            MemoryWriteLog.Entry(time: Date(), writer: "A2", ok: true, note: "", model: "",
                                 run: CatalogRunLink(path: ".runs/legacy.md", anchor: "round-3"))
        ] {
            XCTAssertNil(MemoryWriteLogRunReader.link(for: entry))
            let result = await MemoryWriteLogRunReader.load(entry, wiki: wiki) { _ in
                XCTFail("无关联旧行和非 C3 行不得读记录")
                return ""
            }
            guard case .unlinked = result else { return XCTFail("旧行应安全忽略") }
            XCTAssertNil(result.message)
        }
    }

    func testPreviewLocationIgnoresAnchorInsideRawCodeAndKeepsLongFullText() throws {
        let anchor = "round-3"
        let marker = "<a id=\"\(anchor)\"></a>"
        let prefix = "# 首部\n\n````json\n\(marker)\n```\n````\n\n" + String(repeating: "前面的完整原文。\n\n", count: 3000)
        let suffix = "\(marker)\n\n## 第 3 轮\n\n" + String(repeating: "目标后的完整原文。\n\n", count: 3000) + "末尾不可丢"
        let content = prefix + suffix
        let location = FileEditorPreviewLocation(content: content, anchor: anchor)
        XCTAssertEqual(location.targetIndex, 1)
        XCTAssertEqual(location.parts, [prefix, suffix])
        XCTAssertEqual(location.parts.joined(), content)
        let missing = FileEditorPreviewLocation(content: content, anchor: "不存在")
        XCTAssertNil(missing.targetIndex)
        XCTAssertEqual(missing.parts, [content])
    }

    func testMultilineFencedAndLongTopicsKeepFileBodyAndAnchorsIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let topics = [
            "电影\n```markdown\n# 假标题\n```\n目录/反\\斜杠 *强调* [链接](路径)",
            "主题\r\n~~~~\r\n<a id=\"forged\"></a>\r\n~~~~",
            String(repeating: "超长/主题\\`", count: 2000) + "\n主题末尾"
        ]
        for topic in topics {
            let run = CatalogRunRecord(wiki: wiki, topic: topic, kind: "测试\n`方式`")
            let first = run.section("第 1 轮 · \(topic)", body: CatalogRunRecord.code(topic))
            let second = run.section("第 2 轮", body: CatalogRunRecord.code("末轮\n```\n原文末尾"))
            await run.flush()
            XCTAssertEqual(run.url.deletingLastPathComponent(), wiki.root.appendingPathComponent(".runs"))
            XCTAssertLessThanOrEqual(run.url.lastPathComponent.utf8.count, 255)
            XCTAssertFalse(run.url.lastPathComponent.contains { $0.isNewline || $0 == "/" || $0 == "\\" })
            XCTAssertEqual(CatalogRunRecord.resolve(run.link(anchor: second), wiki: wiki), run.url)
            let content = try String(contentsOf: run.url, encoding: .utf8)
            XCTAssertTrue(content.contains(CatalogRunRecord.code(topic)), "正文必须保留主题全文")
            let heading = try XCTUnwrap(content.split(separator: "\n").first)
            XCTAssertFalse(heading.contains("```"), "标题不能带原样 Markdown 围栏")
            XCTAssertTrue(content.contains("方式：测试 \\`方式\\`"))
            for anchor in [first, second] {
                let location = FileEditorPreviewLocation(content: content, anchor: anchor)
                let index = try XCTUnwrap(location.targetIndex, "动态主题不能吞掉后面的轮次锚点")
                XCTAssertTrue(location.parts[index].hasPrefix("<a id=\"\(anchor)\"></a>"))
                XCTAssertEqual(location.parts.joined(), content)
            }
        }
    }

    @MainActor
    func testAgentLogCanResolvePersistedRoundImmediatelyWithoutPreflush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousRoot = FileLibraryStore.testRootOverride
        FileLibraryStore.testRootOverride = root.appendingPathComponent("library")
        defer {
            MemoryWriteLog.flush()
            FileLibraryStore.testRootOverride = previousRoot
            try? FileManager.default.removeItem(at: root)
        }
        let pid = "run-race-\(UUID().uuidString)"
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let run = CatalogRunRecord(wiki: wiki, topic: "竞态", kind: "测试")
        let backend = FakeCatalogBackend { round, _ in
            if round == 1 { return .toolCalls([CatalogTestKit.call("list_wiki", "{}")]) }
            return .failed("错误原文\n```\n## 不能改变结构\n~~~")
        }
        backend.tokens = { _ in ["模型正文完整收尾"] }
        var gates = 0
        var observed = 0
        let agent = CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in
            gates += 1
            if gates == 1 {
                let backlog = CatalogRunRecord.code(String(repeating: "后台积压原文", count: 40_000))
                for _ in 0..<24 { run.section("写盘积压", body: backlog) }
            } else {
                let rows = await Task.detached { MemoryWriteLog.entries(profileId: pid) }.value
                guard let entry = rows.first else {
                    XCTFail("上一轮日志必须已发布")
                    return nil
                }
                let result = await MemoryWriteLogRunReader.load(entry, wiki: wiki)
                guard case .loaded(let document) = result else {
                    XCTFail("日志出现时记录必须已经可读")
                    return nil
                }
                guard let anchor = entry.run?.anchor else {
                    XCTFail("每轮日志必须关联锚点")
                    return nil
                }
                XCTAssertNotNil(FileEditorPreviewLocation(content: document.content, anchor: anchor).targetIndex)
                XCTAssertTrue(document.content.contains("模型正文完整收尾"), "对应轮次必须完整落盘")
                observed += 1
            }
            return nil
        }))
        let input = CatalogAgent.Job(topic: "电影\n```", profileId: pid, memoryRoot: root,
                                     names: CatalogTestKit.names, floorPrompt: "", snapshot: [], modelName: "fake", run: run)
        let outcome = await agent.run(input)
        XCTAssertEqual(outcome.rounds, 2)
        XCTAssertEqual(observed, 1, "必须在 agent 尚未结束时消费上一轮日志")
        let end = try String(contentsOf: run.url, encoding: .utf8)
        let last = try XCTUnwrap(run.latestAnchor)
        XCTAssertNotNil(FileEditorPreviewLocation(content: end, anchor: last).targetIndex, "错误围栏不能吞掉结束锚点")
        XCTAssertTrue(end.contains(CatalogRunRecord.code("failed：错误原文\n```\n## 不能改变结构\n~~~")))
    }

    @MainActor
    func testSessionLogsAndWriterErrorsPreserveAnchorsWithoutPreflush() async throws {
        let message = "模型失败\n```\n# 伪标题\n~~~"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousRoot = FileLibraryStore.testRootOverride
        FileLibraryStore.testRootOverride = root.appendingPathComponent("library")
        defer {
            MemoryWriteLog.flush()
            FileLibraryStore.testRootOverride = previousRoot
            try? FileManager.default.removeItem(at: root)
        }
        let cc = root.appendingPathComponent("cc")
        try FileManager.default.createDirectory(at: cc, withIntermediateDirectories: true)
        try "---\nname: 主题\ntype: user\n---\n合成记忆".write(to: cc.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let pid = "session-race-\(UUID().uuidString)"
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let backend = FakeCatalogBackend { _, _ in .failed(message) }
        let report = await CatalogSession(job: CatalogTestKit.job(pid: pid, root: root, container: container, backend: backend)).seed()
        XCTAssertEqual(report.failures.count, 1)
        let rows = await Task.detached { MemoryWriteLog.entries(profileId: pid) }.value
        XCTAssertGreaterThanOrEqual(rows.count, 3)
        for entry in rows {
            guard case .loaded(let document) = await MemoryWriteLogRunReader.load(entry, wiki: wiki) else { return XCTFail("每条日志都能打开同一次记录") }
            XCTAssertNotNil(FileEditorPreviewLocation(content: document.content, anchor: entry.run?.anchor).targetIndex)
        }
        let errorRow = try XCTUnwrap(rows.first { !$0.ok && $0.note.hasPrefix("种子：") && $0.note.contains("模型失败") })
        guard case .loaded(let document) = await MemoryWriteLogRunReader.load(errorRow, wiki: wiki) else {
            return XCTFail("错误摘要的日志仍应可打开")
        }
        XCTAssertTrue(document.content.contains(CatalogRunRecord.code(errorRow.note)))
        XCTAssertNotNil(FileEditorPreviewLocation(content: document.content, anchor: errorRow.run?.anchor).targetIndex)
        XCTAssertTrue(document.content.contains(CatalogRunRecord.code(message)), "服务商原话原样进记录")
    }

    @MainActor
    func testSeedRunKeepsSourceAndValidationWithoutWritingWikiPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cc = root.appendingPathComponent("cc")
        try FileManager.default.createDirectory(at: cc, withIntermediateDirectories: true)
        try "---\nname: 电影\ntype: user\n---\n喜欢科幻电影".write(to: cc.appendingPathComponent("movies.md"), atomically: true, encoding: .utf8)
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let model = SeedModel()
        model.wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        model.outline = [["path": "楼层/主题/电影", "kind": "主题", "title": "电影", "sources": ["memory/cc/movies.md"]]]
        let job = CatalogTestKit.job(pid: "", root: root, container: container, backend: model.backend)
        let report = await CatalogSession(job: job).seed()
        XCTAssertEqual(report.items, 1)
        let folder = root.appendingPathComponent("wiki/.runs")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertTrue(text.contains("memory/cc/movies.md"))
        XCTAssertTrue(text.contains("喜欢科幻电影"), "文件调用的完整回执进记录")
        XCTAssertTrue(text.contains("\"phase\":\"outline\""), "交的目录原参数进记录")
        XCTAssertEqual(job.wiki.pagePaths(), [], "运行记录不能变成 wiki 页")
    }
}
