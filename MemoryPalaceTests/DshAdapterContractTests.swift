#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-d dsh：照抄 Wake `dsh_parse_contract` + `dsh_torn_final_frame_terminates`（夹具 = Wake 明文用 zstd CLI 压成真实写端的两帧布局，
/// 另放一个子代理会话）+ seq 契约 + 明文后缀 / 多帧解压逐字节 / 平局裁决 / 缺根降级。全在 tmp
final class DshAdapterContractTests: XCTestCase {
    private var home: URL!
    private var project: URL { home.appendingPathComponent(".dsh/sessions/--Users-tester-Github-wakefx--") }
    private var log: URL { project.appendingPathComponent("dsh-e2e4-0001/session.jsonl.zstd") }
    private var fixtures: URL { CodingSessionAdapterTests.fixtures.appendingPathComponent("dsh") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-dsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("session.jsonl.zstd"), to: log)
        let sub = project.appendingPathComponent("dsh-sub-0002")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try (#"{"type":"session","version":0,"id":"dsh-sub-0002","createdAt":1786100000000,"cwd":"/Users/tester/Github/wakefx","origin":"subagent","delegationDepth":1}"#
            + "\n" + #"{"type":"user/message","seq":0,"time":1786100001000,"data":{"id":"m","role":"user","content":[{"type":"text","text":"child task"}],"source":{"kind":"user"}}}"#
            + "\n").write(to: sub.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testDshParseContract() throws {
        let adapter = DshAdapter(home: home)
        // fileRef 只认 session.jsonl[.zstd]，native id 取 header 的权威 id（目录名是转义过的 id）；子代理会话在这里滤掉
        let r = try XCTUnwrap(adapter.fileRef(log))
        XCTAssertEqual(r.nativeId, "dsh-e2e4-0001")
        XCTAssertNil(adapter.fileRef(project.appendingPathComponent("dsh-sub-0002/session.jsonl")), "子代理会话不进列表")
        XCTAssertEqual(adapter.listSessionFiles().map(\.nativeId), ["dsh-e2e4-0001"], "两层布局，子代理被滤掉")

        // 压缩配置换挡会两后缀并存：陈旧的一份在 fileRef 就让位
        let stale = log.deletingLastPathComponent().appendingPathComponent("session.jsonl")
        try #"{"type":"session","version":0,"id":"dsh-e2e4-0001","createdAt":1786000000000,"cwd":"/Users/tester/Github/wakefx","delegationDepth":0}"#
            .appending("\n").write(to: stale, atomically: true, encoding: .utf8)
        // 夹具拷贝会带着仓库里的 mtime，按主文件往前推（按当前时间推，夹具一旧过 1 小时就翻转）
        let logDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: logDate.addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        XCTAssertNil(adapter.fileRef(stale), "陈旧 sibling 让位")
        XCTAssertNotNil(adapter.fileRef(log), "较新主文件不受影响")
        try FileManager.default.removeItem(at: stale)

        let s = try adapter.parseSession(r)
        let t = try adapter.parseTranscript(r)
        XCTAssertEqual(s.meta.title, "QR scan dependency fix", "session/title 事件 last-wins")
        XCTAssertEqual(s.meta.key, "dsh:dsh-e2e4-0001")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx", "header cwd，不反推目录名")
        XCTAssertEqual(s.meta.model, "deepseek-chat-v4", "assistant source.model")
        XCTAssertEqual(s.meta.tokensUsed, 3440, "按调用累加 1480 + 1560 + 空载体 400；surfaceOp replace 那条的 99999 不计")
        XCTAssertEqual(s.meta.createdAt, 1_786_100_000_000, "header createdAt")
        XCTAssertEqual(s.meta.updatedAt, 1_786_100_007_000, "最后事件 time")
        XCTAssertEqual(s.meta.messageCount, 2, "注入上下文归 Meta 不计；replace / 空载体都不产生气泡")
        XCTAssertEqual(s.unknownLines, 1, "mystery-row；*-chunks 打包行与 turn/step 边界不计")
        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text", "user/meta", "user/meta"],
                       "连续 assistant step 合并一条；source.kind 非 user 的注入上下文归 Meta")
        let a = t.mainline[1]
        XCTAssertTrue(a.text.hasPrefix("我先查一下扫码组件"))
        XCTAssertTrue(a.text.contains("依赖数组漏了 device"))
        XCTAssertTrue(a.thinking?.contains("依赖数组遗漏") ?? false, "reasoning 块分离进 thinking")
        XCTAssertFalse(a.text.contains("crash on unmount"), "不混入正文")
        XCTAssertEqual(a.toolCalls.count, 1)
        XCTAssertEqual(a.toolCalls.first?.name, "read_file")
        XCTAssertTrue(a.toolCalls.first?.output?.contains("useEffect") ?? false, "tool/result 按 toolCallId 回填")
        XCTAssertEqual(a.toolCalls.first?.isError, false)
        XCTAssertEqual(s.units.map(\.seq), [0, 1])
        try CodingContract.assertSeqContract(adapter, r)
        XCTAssertEqual(adapter.sessionPaths(s.meta), [log.deletingLastPathComponent().path], "删整个会话目录")
    }

    /// 半写的末帧：写端每次 append 一帧，扫描与 dsh 天然并发，必然读到。解码器停在帧中间不能「再读一次」，否则死循环
    func testTornFinalFrameTerminates() throws {
        let full = try Data(contentsOf: log)
        let dir = home.appendingPathComponent("torn/s")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let torn = dir.appendingPathComponent("session.jsonl.zstd")
        try full.dropLast(12).write(to: torn)

        let adapter = DshAdapter(home: home)
        let r = try XCTUnwrap(adapter.fileRef(torn), "header 在首帧、完整，断尾会话照常进列表（内容截止到断点）")
        let done = expectation(description: "torn parse returns")
        var parsed: CodingParsedTranscript?
        DispatchQueue.global().async {
            parsed = try? adapter.parseTranscript(r)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let t = try XCTUnwrap(parsed, "断尾优雅收尾，不是把整个会话判失败")
        XCTAssertGreaterThanOrEqual(t.unknownLines, 1, "断点记一次 unknown")
        XCTAssertEqual(t.meta.nativeId, "dsh-e2e4-0001")
    }

    func testPlaintextSuffixMultiFrameDecodeAndRoots() throws {
        let plain = try Data(contentsOf: fixtures.appendingPathComponent("session.jsonl"))
        let decoded = CodingZstd.decompress(try Data(contentsOf: log))
        XCTAssertFalse(decoded.torn)
        XCTAssertEqual(decoded.data, plain, "两帧直接连接逐字节解回明文")

        // compression: none 的纯文本日志同样解析；平局时 .zstd 赢
        let both = project.appendingPathComponent("plain-1")
        try FileManager.default.createDirectory(at: both, withIntermediateDirectories: true)
        let plainLog = both.appendingPathComponent("session.jsonl")
        try plain.write(to: plainLog)
        let adapter = DshAdapter(home: home)
        let plainRef = try XCTUnwrap(adapter.fileRef(plainLog))
        let fromPlain = try adapter.parseSession(plainRef)
        XCTAssertEqual(fromPlain.meta.title, "QR scan dependency fix")
        XCTAssertEqual(fromPlain.meta.tokensUsed, 3440)
        XCTAssertEqual(fromPlain.unknownLines, 1)
        let zipped = both.appendingPathComponent("session.jsonl.zstd")
        try FileManager.default.copyItem(at: log, to: zipped)
        let tie = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: tie], ofItemAtPath: plainLog.path)
        try FileManager.default.setAttributes([.modificationDate: tie], ofItemAtPath: zipped.path)
        XCTAssertNil(adapter.fileRef(plainLog), "mtime 平局 .zstd 赢")
        XCTAssertNotNil(adapter.fileRef(zipped))

        XCTAssertTrue(DshAdapter(home: URL(fileURLWithPath: "/nonexistent-home")).listSessionFiles().isEmpty, "缺根降级为空")
        XCTAssertNil(DshAdapter.readHeader(plainLog.deletingLastPathComponent().appendingPathComponent("missing.jsonl")))
        XCTAssertTrue(CodingSessionRoster.adapters(home: home, environment: [:])
            .contains { $0.agent == .dsh && $0.dataRoots == [home.appendingPathComponent(".dsh/sessions", isDirectory: true)] })
        let meta = try adapter.parseSession(try XCTUnwrap(adapter.fileRef(log))).meta
        XCTAssertEqual(CodingSessionResume.invocation(for: meta)?.0, "npx", "dsh 是拉起 web，不按会话定点续跑")
    }
}
#endif
